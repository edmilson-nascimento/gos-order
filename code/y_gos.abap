*&---------------------------------------------------------------------*
*& Report  ZPP_GOS_SPOOL_TO_ORDER
*&---------------------------------------------------------------------*
*& Purpose : Reference example of the mature archiving class
*&           ZCL_PP_GOS_ARCHIVE, kept here as a LOCAL final class so the
*&           whole flow can be read in a single file.
*&
*&           Take a spool request produced by a print program, convert
*&           it to PDF and attach it to a process/production order as a
*&           GOS attachment (relation 'ATTA').
*&
*& System  : SAP S/4HANA 2023 (ABAP Platform 2023)
*& Author  : JESUSEDM (based on the productive class by BARATAAN)
*&
*& Note    : Binary content is stored via SO_DOCUMENT_INSERT_API1 with
*&           CONTENTS_HEX (raw hex). SO_OBJECT_INSERT must NOT be used
*&           for PDF: it corrupts binary on SAP_BASIS >= 750.
*&
*& Flow    : 1) IS_ARCHIVE_ACTIVE - customizing check (plant + order type)
*&           2) SPOOL_TO_PDF      - locate spool by name, convert to PDF
*&           3) ARCHIVE_PDF       - store PDF (binary) + link 'ATTA'
*&---------------------------------------------------------------------*
REPORT zpp_gos_spool_to_order.

"=====================================================================
" Local GOS archiving service class
" (local mirror of the global class ZCL_PP_GOS_ARCHIVE)
"=====================================================================
CLASS lcl_gos_archive DEFINITION FINAL.
  PUBLIC SECTION.

    "! Returns ABAP_TRUE when archiving is switched on for the given
    "! plant / order type combination (driven by a fixed-value range).
    CLASS-METHODS is_archive_active
      IMPORTING iv_werks         TYPE werks_d
                iv_auart         TYPE auart
      RETURNING VALUE(rv_active) TYPE abap_bool.

    "! Locates the spool produced for the current user (by spool name and
    "! creation time) and converts it to a PDF xstring. Tries Adobe Forms
    "! first (FPCOMP_CREATE_PDF_FROM_SPOOL) and falls back to ABAP list.
    CLASS-METHODS spool_to_pdf
      IMPORTING iv_rq2name    TYPE rspo2name
                iv_rqcretime  TYPE rspocrtime
      RETURNING VALUE(rv_pdf) TYPE xstring.

    "! Stores the PDF as a SAPoffice document (binary, CONTENTS_HEX) and
    "! links it to the order as a GOS attachment ('ATTA').
    "! Returns ABAP_TRUE when anything failed (no exception raised).
    CLASS-METHODS archive_pdf
      IMPORTING iv_pdf           TYPE xstring
                iv_title         TYPE so_obj_des
                iv_aufnr         TYPE aufnr
                iv_object_type   TYPE sibftypeid DEFAULT 'BUS0001'
      RETURNING VALUE(rv_failed) TYPE abap_bool.

ENDCLASS.

CLASS lcl_gos_archive IMPLEMENTATION.

  METHOD is_archive_active.
    DATA: lv_var   TYPE rvari_vnam,
          lr_auart TYPE RANGE OF auart.

    " Customizing range maintained per plant: ZPP_GOS_ATTACH_<WERKS>
    lv_var = |{ 'ZPP_GOS_ATTACH_' }{ iv_werks }|.

    zcl_ca_utils=>get_fixed_param_range(
      EXPORTING  iv_name              = lv_var
      IMPORTING  er_range             = lr_auart
      EXCEPTIONS wrong_exp_table_type = 1
                 OTHERS               = 2 ).

    IF sy-subrc <> 0 OR lr_auart[] IS INITIAL OR
       NOT iv_auart IN lr_auart.
      rv_active = abap_false.
    ELSE.
      rv_active = abap_true.
    ENDIF.
  ENDMETHOD.

  METHOD spool_to_pdf.
    DATA: ls_rq        TYPE tsp01sys,
          lt_partlist  TYPE TABLE OF adspartdesc,
          ls_partline  LIKE LINE OF lt_partlist,
          lv_confile   TYPE string,
          lt_pdf       TYPE STANDARD TABLE OF tline,
          lv_bytecount TYPE i.

    CLEAR rv_pdf.

    " 1) Get the spool number from TSP01 (retry: spooling may lag)
    DO 5 TIMES.
      SELECT rqident, rqclient, rq0name, rqo1name
        FROM tsp01 UP TO 1 ROWS
        INTO ( @ls_rq-rqident, @ls_rq-rqclient,
               @ls_rq-rq0name, @ls_rq-rqo1name )
       WHERE rqclient  =   @sy-mandt
         AND rq0name   =   'PBFORM'
         AND rq2name   =   @iv_rq2name
         AND rqowner   =   @sy-uname
         AND rqfinal   IN ( 'X', 'C' )
         AND rqcretime GE  @iv_rqcretime
         AND rqerror   =   0
       ORDER BY rqident.                                 "#EC CI_NOFIELD
      ENDSELECT.
      IF sy-subrc = 0.
        EXIT.
      ENDIF.
    ENDDO.

    IF ls_rq-rqident IS INITIAL.
      RETURN.
    ENDIF.

    " 2) Adobe Forms spool -> PDF (FPCOMP_CREATE_PDF_FROM_SPOOL)
    CALL FUNCTION 'RSPO_ADSP_FILL_PARTLIST'
      EXPORTING rq       = ls_rq
      TABLES    partlist = lt_partlist.

    IF lt_partlist[] IS NOT INITIAL.
      READ TABLE lt_partlist INDEX 1 INTO ls_partline.

      CALL FUNCTION 'FPCOMP_CREATE_PDF_FROM_SPOOL'
        EXPORTING  i_spoolid      = ls_rq-rqident
                   i_partnum      = ls_partline-adsnum
        IMPORTING  e_pdf          = rv_pdf
                   e_pdf_file     = lv_confile
        EXCEPTIONS ads_error      = 1
                   usage_error    = 2
                   system_error   = 3
                   internal_error = 4
                   OTHERS         = 5.    "#EC CI_SUBRC ##FM_SUBRC_OK
      IF sy-subrc <> 0.
        CLEAR rv_pdf.
      ENDIF.
    ENDIF.

    IF rv_pdf IS NOT INITIAL.
      RETURN.
    ENDIF.

    " 3) Fallback: interpret the spool as an ABAP list
    CALL FUNCTION 'CONVERT_ABAPSPOOLJOB_2_PDF'
      EXPORTING  src_spoolid              = ls_rq-rqident
                 no_dialog                = abap_true
      IMPORTING  pdf_bytecount            = lv_bytecount
      TABLES     pdf                      = lt_pdf
      EXCEPTIONS err_no_abap_spooljob     = 1
                 err_no_spooljob          = 2
                 err_no_permission        = 3
                 err_conv_not_possible    = 4
                 err_bad_destdevice       = 5
                 user_cancelled           = 6
                 err_spoolerror           = 7
                 err_temseerror           = 8
                 err_btcjob_open_failed   = 9
                 err_btcjob_submit_failed = 10
                 err_btcjob_close_failed  = 11
                 OTHERS                   = 12.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.

    " 4) Binary table -> xstring
    CALL FUNCTION 'SCMS_BINARY_TO_XSTRING'
      EXPORTING input_length = lv_bytecount
      IMPORTING buffer       = rv_pdf
      TABLES    binary_tab   = lt_pdf.
  ENDMETHOD.

  METHOD archive_pdf.
    DATA: ls_folder  TYPE soodk,
          lv_obj_id  TYPE so_obj_id,
          lv_size    TYPE i,
          ls_docdata TYPE sodocchgi1,   " document attributes
          ls_docinfo TYPE sofolenti1,   " folder entry info
          ls_bo      TYPE sibflporb,    " local persistent object ref
          ls_doc     TYPE sibflporb.

    rv_failed = abap_false.

    IF iv_pdf IS INITIAL.
      rv_failed = abap_true.
      RETURN.
    ENDIF.

    " Root folder of the current SAPoffice user
    CALL FUNCTION 'SO_FOLDER_ROOT_ID_GET'
      EXPORTING  region    = 'B'
      IMPORTING  folder_id = ls_folder
      EXCEPTIONS OTHERS    = 1.
    IF sy-subrc <> 0.
      rv_failed = abap_true.
      RETURN.
    ENDIF.

    " Binary content as SOLIX (raw hex - no character conversion)
    lv_size = xstrlen( iv_pdf ).
    DATA(lt_solix) = cl_bcs_convert=>xstring_to_solix( iv_xstring = iv_pdf ).

    ls_docdata-obj_name  = 'SPOOLPDF'.
    ls_docdata-obj_descr = iv_title.
    ls_docdata-obj_langu = sy-langu.
    ls_docdata-doc_size  = lv_size.
    lv_obj_id            = ls_folder.

    CALL FUNCTION 'SO_DOCUMENT_INSERT_API1'
      EXPORTING  folder_id                  = lv_obj_id
                 document_data              = ls_docdata
                 document_type              = 'PDF'
      IMPORTING  document_info              = ls_docinfo
      TABLES     contents_hex               = lt_solix
      EXCEPTIONS folder_not_exist           = 1
                 document_type_not_exist    = 2
                 operation_no_authorization = 3
                 parameter_error            = 4
                 x_error                    = 5
                 enqueue_error              = 6
                 OTHERS                     = 7.
    IF sy-subrc <> 0.
      rv_failed = abap_true.
      RETURN.
    ENDIF.

    ls_bo  = VALUE #( instid = iv_aufnr
                      typeid = iv_object_type
                      catid  = 'BO' ).
    ls_doc = VALUE #( instid = ls_docinfo-doc_id
                      typeid = 'MESSAGE'
                      catid  = 'BO' ).

    TRY.
        cl_binary_relation=>create_link(
          is_object_a = ls_bo
          is_object_b = ls_doc
          ip_reltype  = 'ATTA' ).
      CATCH cx_obl_parameter_error cx_obl_model_error cx_obl_internal_error.
        rv_failed = abap_true.
        RETURN.
    ENDTRY.

    COMMIT WORK AND WAIT.
  ENDMETHOD.

ENDCLASS.

"=====================================================================
" Selection screen + execution (demo wiring of the 3 steps)
"=====================================================================
PARAMETERS:
  p_werks  TYPE werks_d     OBLIGATORY,
  p_auart  TYPE auart       OBLIGATORY,
  p_rq2nam TYPE rspo2name   OBLIGATORY,           " spool name (RQ2NAME)
  p_rqtime TYPE rspocrtime  OBLIGATORY,           " spool creation time (lower bound)
  p_aufnr  TYPE aufnr       OBLIGATORY,
  p_botype TYPE sibftypeid  DEFAULT 'BUS0001',    " process order business object
  p_descr  TYPE so_obj_des  DEFAULT 'Attachment from spool'.

START-OF-SELECTION.

  " 1) Skip silently when archiving is not active for plant/order type
  IF lcl_gos_archive=>is_archive_active( iv_werks = p_werks
                                         iv_auart = p_auart ) = abap_false.
    MESSAGE |Archiving not active for plant { p_werks } / order type { p_auart }.| TYPE 'S'.
    RETURN.
  ENDIF.

  " 2) Locate the spool and convert it to PDF
  DATA(lv_pdf) = lcl_gos_archive=>spool_to_pdf( iv_rq2name   = p_rq2nam
                                                iv_rqcretime = p_rqtime ).
  IF lv_pdf IS INITIAL.
    MESSAGE |Spool { p_rq2nam } could not be converted to PDF.| TYPE 'E'.
    RETURN.
  ENDIF.

  " 3) Store the PDF and attach it to the order
  IF lcl_gos_archive=>archive_pdf( iv_pdf         = lv_pdf
                                   iv_title       = p_descr
                                   iv_aufnr       = p_aufnr
                                   iv_object_type = p_botype ) = abap_true.
    MESSAGE |Could not attach the PDF to order { p_aufnr ALPHA = OUT }.| TYPE 'E'.
  ELSE.
    MESSAGE |Attachment created on order { p_aufnr ALPHA = OUT }.| TYPE 'S'.
  ENDIF.
