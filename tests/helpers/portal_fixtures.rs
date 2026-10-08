//! Frozen upstream contract fixtures, verbatim from monorepo-incluir
//! `apps/hono-app/docs/contracts/` at 12178459 (PR B orders + monthly-close
//! freeze). The DTOs must parse every body and re-serialize it unchanged.
#![allow(dead_code)]

pub const ORDERS: &str = r#"{
  "GET /orders": {
    "items": [
      {
        "id": "fbad2d0c-ca65-4a36-8f95-86813104b5e1",
        "reference": "IMP-0001",
        "title": "Apostila de Matemática (+1)",
        "revision": 1,
        "version": 1,
        "status": "ready",
        "createdAt": "2026-10-08T00:25:51.086Z",
        "collectedAt": null,
        "printedAt": null,
        "approvedAmountCents": null
      }
    ],
    "nextCursor": null
  },
  "GET /orders/:id (ready)": {
    "order": {
      "id": "fbad2d0c-ca65-4a36-8f95-86813104b5e1",
      "reference": "IMP-0001",
      "title": "Apostila de Matemática (+1)",
      "revision": 1,
      "version": 1,
      "status": "ready",
      "createdAt": "2026-10-08T00:25:51.086Z",
      "collectedAt": null,
      "printedAt": null,
      "approvedAmountCents": null,
      "jobs": [
        {
          "id": "e36b48ed-ff66-497b-b09a-6edb8ca5e443",
          "title": "Apostila de Matemática",
          "copies": 2,
          "instructions": "Frente e verso, grampeado",
          "file": {
            "id": "c7468a6b-13c9-4ded-9e62-d3486f613f2a",
            "name": "matematica.pdf",
            "mime": "application/pdf",
            "bytes": 168,
            "sha256": "e94e64517d2f0768432fb743e6bf6d4f08087429fd74687a50e0c5a0a80723e3"
          }
        },
        {
          "id": "3b336ca6-9a29-450c-9df8-49a87477065c",
          "title": "Lista de Física",
          "copies": 7,
          "instructions": "Só frente, colorido",
          "file": {
            "id": "40c0e7ef-eeed-4059-b96d-6b6f51f5124f",
            "name": "física final.pdf",
            "mime": "application/pdf",
            "bytes": 168,
            "sha256": "95e8fb01ccaa63baf1581c77f838141895a7fac0d86135d8dbc04108b948077c"
          }
        }
      ],
      "currentQuote": null,
      "cancellationReason": null
    }
  },
  "POST /orders/:id/collected": {
    "order": {
      "id": "fbad2d0c-ca65-4a36-8f95-86813104b5e1",
      "reference": "IMP-0001",
      "title": "Apostila de Matemática (+1)",
      "revision": 1,
      "version": 2,
      "status": "files_collected",
      "createdAt": "2026-10-08T00:25:51.086Z",
      "collectedAt": "2026-10-08T00:25:51.121Z",
      "printedAt": null,
      "approvedAmountCents": null,
      "jobs": [
        {
          "id": "e36b48ed-ff66-497b-b09a-6edb8ca5e443",
          "title": "Apostila de Matemática",
          "copies": 2,
          "instructions": "Frente e verso, grampeado",
          "file": {
            "id": "c7468a6b-13c9-4ded-9e62-d3486f613f2a",
            "name": "matematica.pdf",
            "mime": "application/pdf",
            "bytes": 168,
            "sha256": "e94e64517d2f0768432fb743e6bf6d4f08087429fd74687a50e0c5a0a80723e3"
          }
        },
        {
          "id": "3b336ca6-9a29-450c-9df8-49a87477065c",
          "title": "Lista de Física",
          "copies": 7,
          "instructions": "Só frente, colorido",
          "file": {
            "id": "40c0e7ef-eeed-4059-b96d-6b6f51f5124f",
            "name": "física final.pdf",
            "mime": "application/pdf",
            "bytes": 168,
            "sha256": "95e8fb01ccaa63baf1581c77f838141895a7fac0d86135d8dbc04108b948077c"
          }
        }
      ],
      "currentQuote": null,
      "cancellationReason": null
    }
  },
  "POST /orders/:id/quotes": {
    "order": {
      "id": "fbad2d0c-ca65-4a36-8f95-86813104b5e1",
      "reference": "IMP-0001",
      "title": "Apostila de Matemática (+1)",
      "revision": 1,
      "version": 3,
      "status": "quote_pending",
      "createdAt": "2026-10-08T00:25:51.086Z",
      "collectedAt": "2026-10-08T00:25:51.121Z",
      "printedAt": null,
      "approvedAmountCents": null,
      "jobs": [
        {
          "id": "e36b48ed-ff66-497b-b09a-6edb8ca5e443",
          "title": "Apostila de Matemática",
          "copies": 2,
          "instructions": "Frente e verso, grampeado",
          "file": {
            "id": "c7468a6b-13c9-4ded-9e62-d3486f613f2a",
            "name": "matematica.pdf",
            "mime": "application/pdf",
            "bytes": 168,
            "sha256": "e94e64517d2f0768432fb743e6bf6d4f08087429fd74687a50e0c5a0a80723e3"
          }
        },
        {
          "id": "3b336ca6-9a29-450c-9df8-49a87477065c",
          "title": "Lista de Física",
          "copies": 7,
          "instructions": "Só frente, colorido",
          "file": {
            "id": "40c0e7ef-eeed-4059-b96d-6b6f51f5124f",
            "name": "física final.pdf",
            "mime": "application/pdf",
            "bytes": 168,
            "sha256": "95e8fb01ccaa63baf1581c77f838141895a7fac0d86135d8dbc04108b948077c"
          }
        }
      ],
      "currentQuote": {
        "id": "d3d87db6-ad6c-4330-bec0-753b83991446",
        "revision": 1,
        "orderRevision": 1,
        "amountCents": 45900,
        "currency": "BRL",
        "document": {
          "id": "d3d87db6-ad6c-4330-bec0-753b83991446",
          "name": "orcamento.pdf",
          "mime": "application/pdf",
          "bytes": 136,
          "sha256": "e635e58c529df14d9e4addb50c1d05ccab160483fd6845adafdb041a415bf79e"
        },
        "decision": "pending",
        "rejectionReason": null,
        "submittedAt": "2026-10-08T00:25:51.132Z",
        "decidedAt": null
      },
      "cancellationReason": null
    }
  },
  "POST /orders/:id/printed": {
    "order": {
      "id": "fbad2d0c-ca65-4a36-8f95-86813104b5e1",
      "reference": "IMP-0001",
      "title": "Apostila de Matemática (+1)",
      "revision": 1,
      "version": 5,
      "status": "printed",
      "createdAt": "2026-10-08T00:25:51.086Z",
      "collectedAt": "2026-10-08T00:25:51.121Z",
      "printedAt": "2026-10-08T00:25:51.162Z",
      "approvedAmountCents": 45900,
      "jobs": [
        {
          "id": "e36b48ed-ff66-497b-b09a-6edb8ca5e443",
          "title": "Apostila de Matemática",
          "copies": 2,
          "instructions": "Frente e verso, grampeado",
          "file": {
            "id": "c7468a6b-13c9-4ded-9e62-d3486f613f2a",
            "name": "matematica.pdf",
            "mime": "application/pdf",
            "bytes": 168,
            "sha256": "e94e64517d2f0768432fb743e6bf6d4f08087429fd74687a50e0c5a0a80723e3"
          }
        },
        {
          "id": "3b336ca6-9a29-450c-9df8-49a87477065c",
          "title": "Lista de Física",
          "copies": 7,
          "instructions": "Só frente, colorido",
          "file": {
            "id": "40c0e7ef-eeed-4059-b96d-6b6f51f5124f",
            "name": "física final.pdf",
            "mime": "application/pdf",
            "bytes": 168,
            "sha256": "95e8fb01ccaa63baf1581c77f838141895a7fac0d86135d8dbc04108b948077c"
          }
        }
      ],
      "currentQuote": {
        "id": "d3d87db6-ad6c-4330-bec0-753b83991446",
        "revision": 1,
        "orderRevision": 1,
        "amountCents": 45900,
        "currency": "BRL",
        "document": {
          "id": "d3d87db6-ad6c-4330-bec0-753b83991446",
          "name": "orcamento.pdf",
          "mime": "application/pdf",
          "bytes": 136,
          "sha256": "e635e58c529df14d9e4addb50c1d05ccab160483fd6845adafdb041a415bf79e"
        },
        "decision": "approved",
        "rejectionReason": null,
        "submittedAt": "2026-10-08T00:25:51.132Z",
        "decidedAt": "2026-10-08T00:25:51.147Z"
      },
      "cancellationReason": null
    }
  },
  "error 404": {
    "error": {
      "code": "NOT_FOUND",
      "message": "Recurso não encontrado.",
      "requestId": ""
    }
  },
  "error 412": {
    "error": {
      "code": "VERSION_MISMATCH",
      "message": "O pedido foi atualizado. Consulte novamente antes de repetir.",
      "requestId": ""
    }
  },
  "error 428": {
    "error": {
      "code": "PRECONDITION_REQUIRED",
      "message": "Cabeçalhos If-Match e Idempotency-Key são obrigatórios.",
      "requestId": ""
    }
  },
  "error 401": {
    "error": {
      "code": "UNAUTHORIZED",
      "message": "Credencial inválida.",
      "requestId": ""
    }
  }
}"#;

pub const MONTHLY_CLOSES: &str = r#"{
  "bodies": {
    "GET /monthly-closes/:competence (no prints: virtual)": {
      "close": {
        "id": null,
        "competence": "2026-09",
        "version": 0,
        "state": "open",
        "periodClosed": true,
        "items": [],
        "expectedTotalCents": 0,
        "declaredTotalCents": null,
        "document": null,
        "rejectionReason": null,
        "submittedAt": null,
        "acceptedAt": null
      }
    },
    "GET /monthly-closes/:competence (open, period closed)": {
      "close": {
        "id": "6c4c6b8e-2106-4fec-a2e6-be3d74ac7b58",
        "competence": "2026-09",
        "version": 3,
        "state": "open",
        "periodClosed": true,
        "items": [
          {
            "orderId": "229ec3dd-c2be-44f3-8bea-e41611124659",
            "reference": "IMP-0001",
            "quoteId": "c76057ae-a6cc-4a94-b65b-80dadd2e551e",
            "amountCents": 45900,
            "printedAt": "2026-09-10T12:00:00.000Z"
          },
          {
            "orderId": "58745edd-85b7-4dbf-bb67-7ad7bd751e93",
            "reference": "IMP-0002",
            "quoteId": "47353c22-a8e7-48a7-b280-9901f92ff48d",
            "amountCents": 12000,
            "printedAt": "2026-09-22T12:00:00.000Z"
          }
        ],
        "expectedTotalCents": 57900,
        "declaredTotalCents": null,
        "document": null,
        "rejectionReason": null,
        "submittedAt": null,
        "acceptedAt": null
      }
    },
    "GET /monthly-closes/:competence (current month, period open)": {
      "close": {
        "id": null,
        "competence": "2026-10",
        "version": 0,
        "state": "open",
        "periodClosed": false,
        "items": [],
        "expectedTotalCents": 0,
        "declaredTotalCents": null,
        "document": null,
        "rejectionReason": null,
        "submittedAt": null,
        "acceptedAt": null
      }
    },
    "POST /monthly-closes/:competence/invoice": {
      "close": {
        "id": "6c4c6b8e-2106-4fec-a2e6-be3d74ac7b58",
        "competence": "2026-09",
        "version": 4,
        "state": "submitted",
        "periodClosed": true,
        "items": [
          {
            "orderId": "229ec3dd-c2be-44f3-8bea-e41611124659",
            "reference": "IMP-0001",
            "quoteId": "c76057ae-a6cc-4a94-b65b-80dadd2e551e",
            "amountCents": 45900,
            "printedAt": "2026-09-10T12:00:00.000Z"
          },
          {
            "orderId": "58745edd-85b7-4dbf-bb67-7ad7bd751e93",
            "reference": "IMP-0002",
            "quoteId": "47353c22-a8e7-48a7-b280-9901f92ff48d",
            "amountCents": 12000,
            "printedAt": "2026-09-22T12:00:00.000Z"
          }
        ],
        "expectedTotalCents": 57900,
        "declaredTotalCents": 57000,
        "document": {
          "id": "77e1957c-c712-4787-a73c-7966ba71f06f",
          "name": "NF setembro.pdf",
          "mime": "application/pdf",
          "bytes": 139,
          "sha256": "be4325f7ded8e3cd752d0454635c79002a624e7778599b81e65138dc70692319"
        },
        "rejectionReason": null,
        "submittedAt": "2026-10-15T15:00:00.000Z",
        "acceptedAt": null
      }
    },
    "GET /monthly-closes/:competence (rejected)": {
      "close": {
        "id": "6c4c6b8e-2106-4fec-a2e6-be3d74ac7b58",
        "competence": "2026-09",
        "version": 5,
        "state": "rejected",
        "periodClosed": true,
        "items": [
          {
            "orderId": "229ec3dd-c2be-44f3-8bea-e41611124659",
            "reference": "IMP-0001",
            "quoteId": "c76057ae-a6cc-4a94-b65b-80dadd2e551e",
            "amountCents": 45900,
            "printedAt": "2026-09-10T12:00:00.000Z"
          },
          {
            "orderId": "58745edd-85b7-4dbf-bb67-7ad7bd751e93",
            "reference": "IMP-0002",
            "quoteId": "47353c22-a8e7-48a7-b280-9901f92ff48d",
            "amountCents": 12000,
            "printedAt": "2026-09-22T12:00:00.000Z"
          }
        ],
        "expectedTotalCents": 57900,
        "declaredTotalCents": 57000,
        "document": {
          "id": "77e1957c-c712-4787-a73c-7966ba71f06f",
          "name": "NF setembro.pdf",
          "mime": "application/pdf",
          "bytes": 139,
          "sha256": "be4325f7ded8e3cd752d0454635c79002a624e7778599b81e65138dc70692319"
        },
        "rejectionReason": "Valor diverge do total dos orçamentos aprovados",
        "submittedAt": "2026-10-15T15:00:00.000Z",
        "acceptedAt": null
      }
    },
    "GET /monthly-closes/:competence (accepted)": {
      "close": {
        "id": "6c4c6b8e-2106-4fec-a2e6-be3d74ac7b58",
        "competence": "2026-09",
        "version": 7,
        "state": "accepted",
        "periodClosed": true,
        "items": [
          {
            "orderId": "229ec3dd-c2be-44f3-8bea-e41611124659",
            "reference": "IMP-0001",
            "quoteId": "c76057ae-a6cc-4a94-b65b-80dadd2e551e",
            "amountCents": 45900,
            "printedAt": "2026-09-10T12:00:00.000Z"
          },
          {
            "orderId": "58745edd-85b7-4dbf-bb67-7ad7bd751e93",
            "reference": "IMP-0002",
            "quoteId": "47353c22-a8e7-48a7-b280-9901f92ff48d",
            "amountCents": 12000,
            "printedAt": "2026-09-22T12:00:00.000Z"
          }
        ],
        "expectedTotalCents": 57900,
        "declaredTotalCents": 57900,
        "document": {
          "id": "78c22679-9262-4961-ba29-48e197ab876d",
          "name": "NF setembro.pdf",
          "mime": "application/pdf",
          "bytes": 139,
          "sha256": "be4325f7ded8e3cd752d0454635c79002a624e7778599b81e65138dc70692319"
        },
        "rejectionReason": null,
        "submittedAt": "2026-10-15T15:00:00.000Z",
        "acceptedAt": "2026-10-15T15:00:00.000Z"
      }
    }
  },
  "etags": {
    "GET /monthly-closes/:competence (no prints: virtual)": "\"month:2026-09:0\"",
    "GET /monthly-closes/:competence (open, period closed)": "\"6c4c6b8e-2106-4fec-a2e6-be3d74ac7b58:3\"",
    "GET /monthly-closes/:competence (current month, period open)": "\"month:2026-10:0\"",
    "POST /monthly-closes/:competence/invoice": "\"6c4c6b8e-2106-4fec-a2e6-be3d74ac7b58:4\"",
    "GET /monthly-closes/:competence (rejected)": "\"6c4c6b8e-2106-4fec-a2e6-be3d74ac7b58:5\"",
    "GET /monthly-closes/:competence (accepted)": "\"6c4c6b8e-2106-4fec-a2e6-be3d74ac7b58:7\""
  }
}"#;
