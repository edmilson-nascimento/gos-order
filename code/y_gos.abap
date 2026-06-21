*&---------------------------------------------------------------------*
*& Report  ZPP_GOS_SPOOL_TO_ORDER
*&---------------------------------------------------------------------*
*& Purpose : Take a spool request, convert it to PDF and attach it to a
*&           manufacturing/process order as a GOS attachment (ATTA).
*& System  : SAP S/4HANA 2023 (ABAP Platform 2023)
*& Author  : JESUSEDM
*& Note    : GOS is a Classic API (Clean Core level B, on-premise only).
*&           Local class now; to be promoted to a global class later.
*& Flow    : 1) validate order  2) spool -> PDF  3) store PDF in SAPoffice
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

    "! Reads the spool, converts it to PDF and creates the GOS
    "! attachment on the given order.
    METHODS create_from_spool
      IMPORTING iv_spool_id    TYPE rspoid
                iv_order       TYPE aufnr
                iv_object_type TYPE swo_objtyp DEFAULT 'BUS2005'
                iv_title       TYPE so_obj_des DEFAULT 'Attachment from spool'
      RAISING   lcx_gos_error.

  PRIVATE SECTION.
    "! Converts a spool request (ABAP list or OTF) into a PDF xstring.
    METHODS spool_to_pdf
      IMPORTING iv_spool_id  TYPE rspoid
      EXPORTING ev_pdf       TYPE xstring
                ev_bytecount TYPE i
      RAISING   lcx_gos_error.

    "! Stores a PDF xstring as a SAPoffice document and returns the
    "! BOR identifier (MESSAGE) used to link it to a business object.
    METHODS store_pdf_document
      IMPORTING iv_pdf           TYPE xstring
                iv_bytecount     TYPE i
                iv_title         TYPE so_obj_des
                iv_filename      TYPE string
      RETURNING VALUE(rs_doc_object) TYPE borident
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

    " 3) Binary table -> xstring (byte count guarantees an intact PDF)
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
    " xstring -> SOLIX -> SOLI (binary content for SAPoffice)
    DATA(lt_solix) = cl_bcs_convert=>xstring_to_solix( iv_xstring = iv_pdf ).

    DATA lt_soli TYPE soli_tab.
    CALL FUNCTION 'SO_SOLIXTAB_TO_SOLITAB'
      EXPORTING ip_solixtab = lt_solix
      IMPORTING ep_solitab  = lt_soli.

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

    " Document header attributes
    DATA ls_objdata TYPE sood1.
    ls_objdata-objsns   = 'O'.              " standard sensitivity
    ls_objdata-objla    = sy-langu.
    ls_objdata-objdes   = iv_title.
    ls_objdata-file_ext = 'PDF'.
    ls_objdata-objlen   = iv_bytecount.     " exact PDF size

    " File name + binary format flag
    DATA lt_objhead TYPE STANDARD TABLE OF soli.
    APPEND VALUE #( line = |&SO_FILENAME={ iv_filename }| ) TO lt_objhead.
    APPEND VALUE #( line = |&SO_FORMAT=BIN| )              TO lt_objhead.

    " Insert the external (PC) document into SAPoffice
    DATA ls_obj_id TYPE soodk.
    CALL FUNCTION 'SO_OBJECT_INSERT'
      EXPORTING  folder_id                  = ls_folder
                 object_type                = 'EXT'
                 object_hd_change           = ls_objdata
      IMPORTING  object_id                  = ls_obj_id
      TABLES     objhead                    = lt_objhead
                 objcont                    = lt_soli
      EXCEPTIONS active_user_not_exist      = 1
                 communication_failure      = 2
                 component_not_available    = 3
                 dl_name_exist              = 4
                 folder_not_exist           = 5
                 folder_no_authorization    = 6
                 object_type_not_exist      = 7
                 operation_no_authorization = 8
                 owner_not_exist            = 9
                 parameter_error            = 10
                 substitute_not_active      = 11
                 substitute_not_defined     = 12
                 system_failure             = 13
                 x_error                    = 14
                 OTHERS                     = 15.
    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE lcx_gos_error
        EXPORTING iv_text = |Could not store SAPoffice document. SY-SUBRC={ sy-subrc }|.
    ENDIF.

    " Build the SAPoffice document key (folder + document) for the
    " MESSAGE business object that GOS links to.
    DATA ls_folmem TYPE sofmk.
    ls_folmem-foltp = ls_folder-objtp.
    ls_folmem-folyr = ls_folder-objyr.
    ls_folmem-folno = ls_folder-objno.
    ls_folmem-doctp = ls_obj_id-objtp.
    ls_folmem-docyr = ls_obj_id-objyr.
    ls_folmem-docno = ls_obj_id-objno.

    rs_doc_object-objtype = 'MESSAGE'.
    rs_doc_object-objkey  = ls_folmem.
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

    " 3) Store the PDF as a SAPoffice document
    DATA(ls_doc) = store_pdf_document(
      iv_pdf       = lv_pdf
      iv_bytecount = lv_size
      iv_title     = iv_title
      iv_filename  = |ATTACH_{ lv_aufnr }.PDF| ).

    " 4) Link the document to the order as a GOS attachment (ATTA)
    DATA ls_bo TYPE borident.
    ls_bo-objtype = iv_object_type.
    ls_bo-objkey  = lv_aufnr.

    CALL FUNCTION 'BINARY_RELATION_CREATE_COMMIT'
      EXPORTING  obj_rolea      = ls_bo
                 obj_roleb      = ls_doc
                 relationtype   = 'ATTA'
      EXCEPTIONS no_model       = 1
                 internal_error = 2
                 unknown        = 3
                 OTHERS         = 4.
    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE lcx_gos_error
        EXPORTING iv_text = |Could not link attachment to order. SY-SUBRC={ sy-subrc }|.
    ENDIF.
    " BINARY_RELATION_CREATE_COMMIT commits the whole LUW internally.
  ENDMETHOD.

ENDCLASS.

"=====================================================================
" Selection screen + execution
"=====================================================================
PARAMETERS:
  p_spool  TYPE rspoid      OBLIGATORY,
  p_aufnr  TYPE aufnr       OBLIGATORY,
  p_botype TYPE swo_objtyp  DEFAULT 'BUS2005',   " confirm BO type for COR3
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