# Sample document

The bundled demo uses the Danfoss VLT Midi Drive FC 280 operating instructions with `ORD-1001`. The PDF is not stored in this repository.

Official source:

- [Danfoss VLT Midi Drive FC 280 operating instructions](https://files.danfoss.com/download/Drives/MG07A102.pdf)

The tested document has SHA-256:

```text
a1432e55f3ff76468a3e85738f543f824059ad13e0d9980d1af65d4a40d3ee77
```

Download, verify, and upload the tested document directly from Danfoss with:

```bash
./scripts/fetch_and_upload_danfoss.sh
```

The command stops if the vendor download no longer matches the tested checksum. The vendor name, product name, trademarks, and document copyright remain with their respective owner.
