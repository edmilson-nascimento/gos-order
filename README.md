# GOS Order - Anexar Spool em Production Order (PP)

[![SAP](https://img.shields.io/badge/SAP-0FAADC?style=for-the-badge&logo=sap&logoColor=white)](https://www.sap.com/)
[![ABAP](https://img.shields.io/badge/ABAP-FF6B35?style=for-the-badge&logo=abap&logoColor=white)](https://en.wikipedia.org/wiki/ABAP)
[![SAP Cloud](https://img.shields.io/badge/ABAP%20Cloud-0FAADC?style=for-the-badge&logoColor=white)](https://help.sap.com/docs/sap-abap-cloud)
[![HANA](https://img.shields.io/badge/SAP%20HANA-009EB8?style=for-the-badge&logoColor=white)](https://www.sap.com/products/hana.html)
[![Eclipse ADT](https://img.shields.io/badge/Eclipse%20ADT-2C3E50?style=for-the-badge&logo=eclipse&logoColor=white)](https://tools.hana.ondemand.com/)
[![GOS](https://img.shields.io/badge/GOS-FF9E1B?style=for-the-badge&logoColor=white)](https://help.sap.com/docs/sap_systems)
[![Spool](https://img.shields.io/badge/Spool%20SP02-00A4EF?style=for-the-badge&logoColor=white)](https://help.sap.com/docs/sap_systems)
[![Production Order](https://img.shields.io/badge/Production%20Order%20PP-27AE60?style=for-the-badge&logoColor=white)](https://en.wikipedia.org/wiki/Manufacturing_execution_system)
[![Generic Objects](https://img.shields.io/badge/Generic%20Objects-E74C3C?style=for-the-badge&logoColor=white)](https://help.sap.com/docs/sap_systems)
[![Repository](https://img.shields.io/badge/Repository-181717?style=for-the-badge&logo=github&logoColor=white)](https://github.com/)

Sistema ABAP SAP para anexar arquivos/documentos em Production Orders (CORN) utilizando **GOS (Generic Object Services)** via classe `CL_GOS_MANAGER`.

## 📋 Visão Geral

Este repositório demonstra como integrar documentos e arquivos em uma Production Order do módulo PP (Planejamento de Produção) usando a classe `CL_GOS_MANAGER` do SAP. Um caso de uso comum é anexar um relatório de spool já existente (SP02) como comprovante na ordem de produção.

### Conceitos Principais

- **GOS (Generic Object Services)**: Framework do SAP que permite anexar documentos, notas e links a objetos de negócios
- **CL_GOS_MANAGER**: Classe principal para gerenciar anexos, notas e links
- **Production Order (CORN)**: Objeto de negócio do módulo PP (Planejamento de Produção)
- **Spool (SP02)**: Documento já processado/impresso no sistema

---

## 🎯 Objetivo

Criar um programa ABAP que:
1. Localiza uma Production Order existente (CORN)
2. Recupera um arquivo de spool (SP02) já existente
3. Anexa esse arquivo/documento à Production Order usando GOS

---

## 🔧 Pré-requisitos

- Sistema SAP com módulo PP ativo
- Classe `CL_GOS_MANAGER` disponível (versão 4.7 ou superior)
- Production Order válida (CORN)
- Spool job já processado e disponível (SP02)
- Acesso a transação SP01/SP02 (Spool)

---

## 📝 Exemplo de Código

### Programa Simples - Anexar Spool a Production Order

```abap
*&---------------------------------------------------------------------*
*& Report  ZGOS_ATTACH_SPOOL_TO_ORDER
*&---------------------------------------------------------------------*
*& Descrição: Anexa um documento de spool a uma Production Order
*&            usando GOS (Generic Object Services)
*&---------------------------------------------------------------------*

REPORT ZGOS_ATTACH_SPOOL_TO_ORDER.

PARAMETERS:
  p_order   TYPE AUFNR DEFAULT '0000100001',  "Production Order (CORN)
  p_spool   TYPE N_OSPHD-SPOOLID.              "Spool ID

DATA:
  lt_attachments TYPE TABLE OF stg_os_attachments,
  ls_attachment  LIKE LINE OF lt_attachments,
  lo_gos_manager TYPE REF TO cl_gos_manager,
  lv_object_key  TYPE gosadmemoty-objkey,
  lv_attachment  TYPE stg_os_attachments,
  lx_exception   TYPE REF TO cx_root.

TRY.
  "1. Construir chave do objeto (Production Order)
  "   Formato: <Documento>-<Número>
  lv_object_key = p_order.

  "2. Criar instância do GOS Manager
  "   - object_type: 'MMBE' = Material, 'CORN' = Production Order, 'VBAK' = Sales Order, etc.
  "   - object_key: Chave do objeto
  "   - is_active: Ativa modo de visualização (TRUE = modo visualização)
  CREATE OBJECT lo_gos_manager
    EXPORTING
      is_mode      = 'E'              "E=Edit, S=Show
      is_object_type = 'CORN'         "Tipo de objeto (Production Order)
      is_object_key  = lv_object_key  "Chave: Número da ordem
      is_object_id   = ' '.

  "3. Buscar anexos existentes (opcional)
  CALL METHOD lo_gos_manager->get_attachments
    IMPORTING
      et_attachments = lt_attachments.

  IF lt_attachments IS NOT INITIAL.
    WRITE: / 'Anexos existentes encontrados:', SY-DBCNT LINES.
  ENDIF.

  "4. Adicionar novo anexo (Spool)
  "   Opção A: Usar BDS (Business Document Service) para anexar arquivo
  ls_attachment-classname = 'SPOOL'.      "Tipo: Spool
  ls_attachment-filename = | Spool_{p_spool}.pdf |.
  ls_attachment-filesize = 0.             "Será preenchido automaticamente
  ls_attachment-langu = SY-LANGU.
  ls_attachment-description = | Spool {p_spool} - Production Order |.

  "5. Anexar usando método ADD_ATTACHMENT
  CALL METHOD lo_gos_manager->add_attachment
    EXPORTING
      ps_attachment = ls_attachment
    IMPORTING
      ps_attachment = ls_attachment.

  "6. Salvar (COMMIT) as alterações
  CALL METHOD lo_gos_manager->save.

  WRITE: / 'Spool anexado com sucesso à Production Order:', p_order.
  WRITE: / 'ID do Arquivo:', ls_attachment-mime_type.

CATCH cx_root INTO lx_exception.
  WRITE: / 'Erro:', lx_exception->get_text( ).
ENDTRY.
```

---

### Exemplo Avançado - Com Recuperação de Spool via TBTCP

```abap
*&---------------------------------------------------------------------*
*& Report  ZGOS_ATTACH_SPOOL_ADVANCED
*&---------------------------------------------------------------------*
*& Descrição: Versão avançada - recupera dados do spool de SP02
*&            e anexa à Production Order
*&---------------------------------------------------------------------*

REPORT ZGOS_ATTACH_SPOOL_ADVANCED.

PARAMETERS:
  p_order   TYPE AUFNR,
  p_jobname TYPE TBTCP-JOBNAME,
  p_jobcount TYPE TBTCP-JOBCOUNT.

DATA:
  lo_gos_manager   TYPE REF TO cl_gos_manager,
  ls_attachment    TYPE stg_os_attachments,
  lt_spool_data    TYPE TABLE OF tbtcp,
  ls_spool         LIKE LINE OF lt_spool_data,
  lv_file_content  TYPE XSTRING,
  lv_object_key    TYPE gosadmemoty-objkey,
  lx_exception     TYPE REF TO cx_root.

TRY.

  "1. Buscar dados do Spool (TBTCP)
  SELECT * FROM tbtcp
    INTO TABLE lt_spool_data
    WHERE jobname = p_jobname
      AND jobcount = p_jobcount.

  IF lt_spool_data IS INITIAL.
    MESSAGE E001 WITH 'Spool não encontrado'.
  ENDIF.

  READ TABLE lt_spool_data INTO ls_spool INDEX 1.

  "2. Criar GOS Manager para a Production Order
  lv_object_key = p_order.

  CREATE OBJECT lo_gos_manager
    EXPORTING
      is_mode        = 'E'
      is_object_type = 'CORN'
      is_object_key  = lv_object_key.

  "3. Preparar anexo com informações do Spool
  ls_attachment-classname = 'SPOOL'.
  ls_attachment-filename = | {ls_spool-jobname}_{ls_spool-jobcount}.txt |.
  ls_attachment-description = | Spool Report - {ls_spool-jobname} |.
  ls_attachment-langu = SY-LANGU.
  ls_attachment-filetype = 'TXT'.

  "4. Adicionar anexo
  CALL METHOD lo_gos_manager->add_attachment
    EXPORTING
      ps_attachment = ls_attachment
    IMPORTING
      ps_attachment = ls_attachment.

  "5. Salvar alterações
  CALL METHOD lo_gos_manager->save.

  WRITE: / 'Spool anexado com sucesso!'.
  WRITE: / 'Production Order: ', p_order.
  WRITE: / 'Job Spool: ', ls_spool-jobname, '/', ls_spool-jobcount.

CATCH cx_root INTO lx_exception.
  WRITE: / 'Erro ao anexar spool:', lx_exception->get_text( ).
ENDTRY.
```

---

### Exemplo - Consultar e Listar Anexos Existentes

```abap
*&---------------------------------------------------------------------*
*& Report  ZGOS_LIST_ATTACHMENTS
*&---------------------------------------------------------------------*
*& Descrição: Lista todos os anexos de uma Production Order
*&---------------------------------------------------------------------*

REPORT ZGOS_LIST_ATTACHMENTS.

PARAMETERS:
  p_order TYPE AUFNR.

DATA:
  lo_gos_manager  TYPE REF TO cl_gos_manager,
  lt_attachments  TYPE TABLE OF stg_os_attachments,
  ls_attachment   LIKE LINE OF lt_attachments,
  lv_object_key   TYPE gosadmemoty-objkey,
  lx_exception    TYPE REF TO cx_root.

TRY.

  lv_object_key = p_order.

  CREATE OBJECT lo_gos_manager
    EXPORTING
      is_mode        = 'S'              "S = Show mode (somente leitura)
      is_object_type = 'CORN'
      is_object_key  = lv_object_key.

  "Obter lista de anexos
  CALL METHOD lo_gos_manager->get_attachments
    IMPORTING
      et_attachments = lt_attachments.

  IF lt_attachments IS INITIAL.
    WRITE: / 'Nenhum anexo encontrado para a Production Order:', p_order.
  ELSE.
    WRITE: / 'Anexos da Production Order:', p_order.
    WRITE: / SY-ULINE.
    WRITE: / 'Arquivo', 50, 'Descrição', 100, 'Tipo'.
    WRITE: / SY-ULINE.

    LOOP AT lt_attachments INTO ls_attachment.
      WRITE: / ls_attachment-filename,
              ls_attachment-description,
              ls_attachment-filetype.
    ENDLOOP.
  ENDIF.

CATCH cx_root INTO lx_exception.
  WRITE: / 'Erro:', lx_exception->get_text( ).
ENDTRY.
```

---

## 🔑 Parâmetros Principais de CL_GOS_MANAGER

| Parâmetro | Tipo | Descrição |
|-----------|------|-----------|
| `is_object_type` | CHAR(4) | Tipo de objeto (CORN=Production Order, VBAK=Sales Order, MMBE=Material, etc.) |
| `is_object_key` | STRING | Chave única do objeto (número da ordem, material, etc.) |
| `is_mode` | CHAR(1) | E=Edit, S=Show (somente leitura) |
| `ps_attachment` | STRUCTURE | Estrutura com dados do anexo (filename, description, etc.) |

---

## 📚 Tipos de Objetos Suportados (Exemplos)

| Tipo | Descrição |
|------|-----------|
| `CORN` | Production Order (Ordem de Produção) |
| `VBAK` | Sales Order Header (Pedido de Venda) |
| `MMBE` | Material Stock (Material/Estoque) |
| `EBAN` | Purchase Requisition |
| `EKKO` | Purchase Order Header |
| `MKAL` | Cost Center |

---

## 🚀 Como Usar Este Repositório

1. **Clone o repositório**
   ```bash
   git clone https://github.com/seu-usuario/gos-order.git
   cd gos-order
   ```

2. **Copie os programas** para seu ambiente SAP:
   - Acesse a transação SE38 (Editor ABAP)
   - Crie um novo programa (ex: ZGOS_ATTACH_SPOOL_TO_ORDER)
   - Cole o código do exemplo desejado
   - Salve e execute

3. **Configure os parâmetros**:
   - Production Order (CORN) válida no seu sistema
   - Spool ID (SP02) já existente
   - Execute F8 para testar

---

## ⚠️ Notas Importantes

- **Permissões**: Você deve ter permissão para editar a Production Order (transação CO02)
- **Spool deve existir**: O spool SP02 deve estar processado antes de anexar
- **Commit automático**: Use `COMMIT WORK` após `lo_gos_manager->save()` para garantir persistência
- **Modo de teste**: Comece em modo `S` (Show) para listar anexos existentes

---

## 📖 Referências SAP

- Transação **SE38**: Editor ABAP
- Transação **CO02**: Alteração de Production Order
- Transação **SP01/SP02**: Visualizador de Spool
- Transação **ZGOS**: GOS Business Object Administration

---

## 🤝 Contribuições

Este repositório é um exemplo educacional. Para sugestões ou melhorias, abra uma issue ou pull request.

---

## 📄 Licença

Open Source - Use livremente em seus projetos SAP.

---

**Última atualização:** 2026-06-21  
**Versão:** 1.0
