*&---------------------------------------------------------------------*
*& Report  ZPP_GOS_SPOOL_TO_ORDER
*&---------------------------------------------------------------------*
*& Anexa o PDF de um spool a uma ordem (COR3/CO03) como anexo GOS (ATTA)
*& Autor : JESUSEDM
*& Nota  : GOS = Classic API (Clean Core nivel B). Classe local; sera
*&         promovida a classe global posteriormente.
*&---------------------------------------------------------------------*
REPORT zpp_gos_spool_to_order.

"=====================================================================
" Excecao local (sera substituida por excecao global na versao final)
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
" Classe local de servico GOS
"=====================================================================
CLASS lcl_gos_attachment DEFINITION FINAL CREATE PRIVATE.
  PUBLIC SECTION.
    CLASS-METHODS create_instance
      RETURNING VALUE(ro_instance) TYPE REF TO lcl_gos_attachment.

    "! Apanha o spool, converte em PDF e cria o anexo GOS na ordem.
    METHODS create_from_spool
      IMPORTING iv_spool_id    TYPE rspoid
                iv_order       TYPE aufnr
                iv_object_type TYPE sibftypeid DEFAULT 'BUS2005'
                iv_title       TYPE so_obj_des DEFAULT 'Anexo via spool'
      RAISING   lcx_gos_error.

  PRIVATE SECTION.
    "! Converte um spool (lista ABAP ou OTF) em PDF (xstring).
    METHODS spool_to_pdf
      IMPORTING iv_spool_id  TYPE rspoid
      EXPORTING ev_pdf       TYPE xstring
                ev_bytecount TYPE i
      RAISING   lcx_gos_error.
ENDCLASS.

CLASS lcl_gos_attachment IMPLEMENTATION.

  METHOD create_instance.
    ro_instance = NEW lcl_gos_attachment( ).
  ENDMETHOD.

  METHOD spool_to_pdf.
    DATA lt_pdf TYPE STANDARD TABLE OF tline.

    " 1) Tenta como lista ABAP
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

    " 2) Se nao for lista ABAP, tenta como OTF (SAPscript/Smartforms)
    IF sy-subrc = 4.
      CLEAR: lt_pdf, ev_bytecount.
      CALL FUNCTION 'CONVERT_OTFSPOOLJOB_2_PDF'
        EXPORTING  src_spoolid              = iv_spool_id
                   no_dialog                = abap_true
        IMPORTING  pdf_bytecount            = ev_bytecount
        TABLES     pdf                      = lt_pdf
        EXCEPTIONS err_no_otf_spooljob      = 1
                   err_spoolerror           = 2
                   err_no_permission        = 3
                   err_conv_not_possible    = 4
                   err_bad_dstdevice        = 5
                   user_cancelled           = 6
                   OTHERS                   = 7.
      IF sy-subrc <> 0.
        RAISE EXCEPTION TYPE lcx_gos_error
          EXPORTING iv_text = |Spool { iv_spool_id } (OTF) nao convertido em PDF. SY-SUBRC={ sy-subrc }|.
      ENDIF.
    ELSEIF sy-subrc <> 0.
      RAISE EXCEPTION TYPE lcx_gos_error
        EXPORTING iv_text = |Spool { iv_spool_id } nao convertido em PDF. SY-SUBRC={ sy-subrc }|.
    ENDIF.

    " 3) Tabela binaria -> xstring (bytecount garante PDF integro)
    CALL FUNCTION 'SCMS_BINARY_TO_XSTRING'
      EXPORTING input_length = ev_bytecount
      IMPORTING buffer       = ev_pdf
      TABLES    binary_tab   = lt_pdf.

    IF ev_pdf IS INITIAL.
      RAISE EXCEPTION TYPE lcx_gos_error
        EXPORTING iv_text = |Conteudo PDF vazio apos conversao do spool { iv_spool_id }.|.
    ENDIF.
  ENDMETHOD.

  METHOD create_from_spool.
    " 1) Valida ordem
    DATA(lv_aufnr) = CONV aufnr( |{ iv_order ALPHA = IN }| ).
    SELECT SINGLE aufnr FROM aufk INTO @DATA(lv_dummy) WHERE aufnr = @lv_aufnr.
    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE lcx_gos_error
        EXPORTING iv_text = |Ordem { lv_aufnr ALPHA = OUT } nao encontrada (AUFK).|.
    ENDIF.

    " 2) Spool -> PDF
    spool_to_pdf( EXPORTING iv_spool_id  = iv_spool_id
                  IMPORTING ev_pdf       = DATA(lv_pdf)
                            ev_bytecount = DATA(lv_size) ).

    DATA(lt_solix) = cl_bcs_convert=>xstring_to_solix( iv_xstring = lv_pdf ).

    " 3) Cria documento SAPoffice (pasta raiz do utilizador)
    DATA ls_folder TYPE soodk.
    CALL FUNCTION 'SO_FOLDER_ROOT_ID_GET'
      EXPORTING  region    = 'B'
      IMPORTING  folder_id = ls_folder
      EXCEPTIONS OTHERS    = 1.
    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE lcx_gos_error
        EXPORTING iv_text = |Nao foi possivel obter a pasta raiz do SAPoffice.|.
    ENDIF.

    DATA ls_docdata TYPE sodocchgi1.
    ls_docdata-obj_name  = CONV so_obj_nam( |SP{ iv_spool_id }| ).
    ls_docdata-obj_descr = iv_title.
    ls_docdata-doc_size  = lv_size.            " imprescindivel p/ PDF integro

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
        EXPORTING iv_text = |Falha ao criar documento SAPoffice. SY-SUBRC={ sy-subrc }|.
    ENDIF.

    " 4) Liga o documento a ordem como anexo GOS (relacao ATTA)
    DATA: ls_bo  TYPE sibflporb,
          ls_doc TYPE sibflporb.

    ls_bo  = VALUE #( instid = lv_aufnr
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
      CATCH cx_obl_parameter_error cx_obl_model_error cx_obl_internal_error INTO DATA(lx_obl).
        RAISE EXCEPTION TYPE lcx_gos_error
          EXPORTING iv_text = |Falha ao ligar anexo a ordem: { lx_obl->get_text( ) }|.
    ENDTRY.

    COMMIT WORK AND WAIT.
  ENDMETHOD.

ENDCLASS.

"=====================================================================
" Selection screen + execucao
"=====================================================================
PARAMETERS:
  p_spool  TYPE rspoid      OBLIGATORY,
  p_aufnr  TYPE aufnr       OBLIGATORY,
  p_botype TYPE sibftypeid  DEFAULT 'BUS2005',     " ver nota abaixo
  p_descr  TYPE so_obj_des  DEFAULT 'Anexo via spool'.

START-OF-SELECTION.
  TRY.
      lcl_gos_attachment=>create_instance( )->create_from_spool(
        iv_spool_id    = p_spool
        iv_order       = p_aufnr
        iv_object_type = p_botype
        iv_title       = p_descr ).
      MESSAGE |Anexo criado na ordem { p_aufnr ALPHA = OUT }.| TYPE 'S'.
    CATCH lcx_gos_error INTO DATA(lo_err).
      MESSAGE lo_err->get_text( ) TYPE 'E'.
  ENDTRY.