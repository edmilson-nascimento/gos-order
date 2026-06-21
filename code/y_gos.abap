*&---------------------------------------------------------------------*
*& Report  ZPP_GOS_SPOOL_TO_ORDER
*&---------------------------------------------------------------------*
*& Purpose : Take a spool request, convert it to PDF and attach it to a
*&           process order (COR3) as a GOS attachment (ATTA).
*& System  : SAP S/4HANA 2023 (ABAP Platform 2023)
*& Author  : JESUSEDM
*& Note    : Binary content is stored via SO_DOCUMENT_INSERT_API1 with
*&           CONTENTS_HEX (raw hex). SO_OBJECT_INSERT must NOT be used
*&           for PDF: it corrupts binary on SAP_BASIS >= 750.
*& Flow    : 1) validate order  2) spool -> PDF  3) store PDF (binary)
*&           4) link document to order (binary relation 'ATTA')
*&---------------------------------------------------------------------*
REPORT zpp_gos_spool_to_order.

"=====================================================================
" Local exception (to be replaced by a global ZCX_* in the final class)
"=====================================================================
CLASS lcx_gos_error DEFINITION INHERITING FROM cx_static_check FINAL.
  PUBLIC SECTION.
    METHODS constructor IMPORTING iv_text TYPE string.
    METHODS get_text REDEFINITION.
  PRIVATE SECTION.
    DATA mv_text TYPE string.
ENDCLASS.

CLASS lcx_gos_error IMPLEMENTATION.
  METHOD constructor.
    super->constructor( ).
    mv_text = iv_text.
  ENDMETHOD.
  METHOD get_text.
    result = mv_text.
  ENDMETHOD.
ENDCLASS.

"=====================================================================
" Local GOS service class
"=====================================================================
CLASS lcl_gos_attachment DEFINITION FINAL CREATE PRIVATE.
  PUBLIC SECTION.
    CLASS-METHODS create_instance
      RETURNING VALUE(ro_instance) TYPE REF TO lcl_gos_attachment.

    METHODS create_from_spool
      IMPORTING iv_spool_id    TYPE rspoid
                iv_order       TYPE aufnr
                iv_object_type TYPE sibftypeid DEFAULT 'BUS0001'
                iv_title       TYPE so_obj_des DEFAULT 'Attachment from spool'
      RAISING   lcx_gos_error.

  PRIVATE SECTION.
    METHODS spool_to_pdf
      IMPORTING iv_spool_id  TYPE rspoid
      EXPORTING ev_pdf       TYPE xstring
                ev_bytecount TYPE i
      RAISING   lcx_gos_error.

    "! Stores a PDF xstring as a SAPoffice document (binary, CONTENTS_HEX)
    "! and returns its document id for the GOS link.
    METHODS store_pdf_document
      IMPORTING iv_pdf           TYPE xstring
                iv_title         TYPE so_obj_des
      RETURNING VALUE(rv_doc_id) TYPE sofolenti1-doc_id
      RAISING   lcx_gos_error.
ENDCLASS.

CLASS lcl_gos_attachment IMPLEMENTATION.

  METHOD create_instance.
    ro_instance = NEW lcl_gos_attachment( ).
  ENDMETHOD.

  METHOD spool_to_pdf.
    DATA lt_pdf TYPE STANDARD TABLE OF tline.

    " 1) Try to interpret the spool as an ABAP list
    CALL FUNCTION 'CONVERT_ABAPSPOOLJOB_2_PDF'
      EXPORTING  src_spoolid              = iv_spool_id
                 no_dialog                = abap_true
      IMPORTING  pdf_bytecount            = ev_bytecount
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

    " 2) Not an ABAP list -> fall back to OTF (SAPscript / Smart Forms)
    IF sy-subrc = 4.
      CLEAR: lt_pdf, ev_bytecount.
      CALL FUNCTION 'CONVERT_OTFSPOOLJOB_2_PDF'
        EXPORTING  src_spoolid           = iv_spool_id
                   no_dialog             = abap_true
        IMPORTING  pdf_bytecount         = ev_bytecount
        TABLES     pdf                   = lt_pdf
        EXCEPTIONS err_no_otf_spooljob   = 1
                   err_spoolerror        = 2
                   err_no_permission     = 3
                   err_conv_not_possible = 4
                   err_bad_dstdevice     = 5
                   user_cancelled        = 6
                   OTHERS                = 7.
      IF sy-subrc <> 0.
        RAISE EXCEPTION TYPE lcx_gos_error
          EXPORTING iv_text = |Spool { iv_spool_id } (OTF) could not be converted to PDF. SY-SUBRC={ sy-subrc }|.
      ENDIF.
    ELSEIF sy-subrc <> 0.
      RAISE EXCEPTION TYPE lcx_gos_error
        EXPORTING iv_text = |Spool { iv_spool_id } could not be converted to PDF. SY-SUBRC={ sy-subrc }|.
    ENDIF.

    " 3) Binary table -> xstring
    CALL FUNCTION 'SCMS_BINARY_TO_XSTRING'
      EXPORTING input_length = ev_bytecount
      IMPORTING buffer       = ev_pdf
      TABLES    binary_tab   = lt_pdf.

    IF ev_pdf IS INITIAL.
      RAISE EXCEPTION TYPE lcx_gos_error
        EXPORTING iv_text = |PDF content is empty after converting spool { iv_spool_id }.|.
    ENDIF.
  ENDMETHOD.

  METHOD store_pdf_document.
    " Root folder of the current SAPoffice user
    DATA ls_folder TYPE soodk.
    CALL FUNCTION 'SO_FOLDER_ROOT_ID_GET'
      EXPORTING  region    = 'B'
      IMPORTING  folder_id = ls_folder
      EXCEPTIONS OTHERS    = 1.
    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE lcx_gos_error
        EXPORTING iv_text = |Could not read SAPoffice root folder.|.
    ENDIF.

    " Binary content as SOLIX (raw hex - no character conversion)
    DATA(lt_solix) = cl_bcs_convert=>xstring_to_solix( iv_xstring = iv_pdf ).

    " Document attributes - do NOT set doc_size when using CONTENTS_HEX
    DATA ls_docdata TYPE sodocchgi1.
    ls_docdata-obj_name  = 'SPOOLPDF'.
    ls_docdata-obj_descr = iv_title.

    DATA ls_docinfo TYPE sofolenti1.
    CALL FUNCTION 'SO_DOCUMENT_INSERT_API1'
      EXPORTING  folder_id                  = ls_folder
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
      RAISE EXCEPTION TYPE lcx_gos_error
        EXPORTING iv_text = |Could not store SAPoffice document (SO_DOCUMENT_INSERT_API1). SY-SUBRC={ sy-subrc }|.
    ENDIF.

    rv_doc_id = ls_docinfo-doc_id.
  ENDMETHOD.

  METHOD create_from_spool.
    " 1) Validate the order
    DATA(lv_aufnr) = CONV aufnr( |{ iv_order ALPHA = IN }| ).
    SELECT SINGLE aufnr FROM aufk INTO @DATA(lv_dummy) WHERE aufnr = @lv_aufnr.
    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE lcx_gos_error
        EXPORTING iv_text = |Order { lv_aufnr ALPHA = OUT } not found (AUFK).|.
    ENDIF.

    " 2) Spool -> PDF
    spool_to_pdf( EXPORTING iv_spool_id  = iv_spool_id
                  IMPORTING ev_pdf       = DATA(lv_pdf)
                            ev_bytecount = DATA(lv_size) ).

    " 3) Store the PDF as a SAPoffice document (binary)
    DATA(lv_doc_id) = store_pdf_document(
      iv_pdf   = lv_pdf
      iv_title = iv_title ).

    " 4) Link the document to the order as a GOS attachment (ATTA)
    DATA: ls_bo  TYPE sibflporb,
          ls_doc TYPE sibflporb.

    ls_bo  = VALUE #( instid = lv_aufnr
                      typeid = iv_object_type
                      catid  = 'BO' ).
    ls_doc = VALUE #( instid = lv_doc_id
                      typeid = 'MESSAGE'
                      catid  = 'BO' ).

    TRY.
        cl_binary_relation=>create_link(
          is_object_a = ls_bo
          is_object_b = ls_doc
          ip_reltype  = 'ATTA' ).
      CATCH cx_obl_parameter_error cx_obl_model_error cx_obl_internal_error INTO DATA(lx_obl).
        RAISE EXCEPTION TYPE lcx_gos_error
          EXPORTING iv_text = |Could not link attachment to order: { lx_obl->get_text( ) }|.
    ENDTRY.

    COMMIT WORK AND WAIT.
  ENDMETHOD.

ENDCLASS.

"=====================================================================
" Selection screen + execution
"=====================================================================
PARAMETERS:
  p_spool  TYPE rspoid      OBLIGATORY,
  p_aufnr  TYPE aufnr       OBLIGATORY,
  p_botype TYPE sibftypeid  DEFAULT 'BUS0001',   " process order (COR3)
  p_descr  TYPE so_obj_des  DEFAULT 'Attachment from spool'.

START-OF-SELECTION.
  TRY.
      lcl_gos_attachment=>create_instance( )->create_from_spool(
        iv_spool_id    = p_spool
        iv_order       = p_aufnr
        iv_object_type = p_botype
        iv_title       = p_descr ).
      MESSAGE |Attachment created on order { p_aufnr ALPHA = OUT }.| TYPE 'S'.
    CATCH lcx_gos_error INTO DATA(lo_err).
      MESSAGE lo_err->get_text( ) TYPE 'E'.
  ENDTRY.