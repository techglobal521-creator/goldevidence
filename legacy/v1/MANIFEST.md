# v1 archive manifest (Strategy A, frozen 2026-11-01)

Source: owner's PC, `C:\Users\dell\OneDrive\Desktop\GoldEvidence_v1\GoldEvidence\` (all files mtime 2026-11-02 14:50).

**How this copy was made.** The binary file-copy tool failed, so each file was read as text from the owner's PC
and written here. Each file was then checked against the original's byte size (LF line endings).
All 34 sizes match. This is a size-verified text copy, not a byte-for-byte copy.
If the originals use CRLF line endings, their sha256 values will differ from the ones below.

Evidence that the copy is intact: the v1 Python tests run on this copy give **23 passed**
(`python -m pytest ai_service/tests analysis/tests -q`, run 2026-11-04).

Secret scan: no keys or tokens found. Only test placeholders are present (`sk-test`, `"t"*24`, `"k"`).
`ai_service/config.py` reads the key from an environment variable or the OS keyring.

**Status: reference only.** Nothing here is wired into the build, and nothing here has been changed.
Known issues, recorded but NOT fixed (Strategy A is frozen):
- `MarketData.mqh` still has the BarsCalculated gate bug that gave 0 tester trades. The fix exists only in v2 code, whose location is unknown.
- `OnInit` rejects risk above 0.5% and a daily limit above 2%. This conflicts with profiles P1-S1/S2.
- `GE_ExportNews.mq5` sets the default `InpFrom` to 2020-01-01, so news back to 2015 is not covered (D-13).
- `acceptance_criteria.json` references an architecture doc that is not in the archive.

| Path | Bytes | sha256 (this copy) |
|---|---:|---|
| `MQL5/Experts/GoldEvidence/GoldEvidenceEA.mq5` | 32270 | `808ce6f64ff74ea58429109cc77a7c8579cc1029d6b3f2936a015f236146cf3e` |
| `MQL5/Include/GoldEvidence/AIClient.mqh` | 5760 | `8da6bb31a2b747e75ee25a6a0208607ab187f7a17c0ee4c46be1a018e8402caa` |
| `MQL5/Include/GoldEvidence/Execution.mqh` | 3404 | `98a61ddac037290a2c8f2ecd75a1ea6bb21565ed3ee0f257da5db54da6f200dc` |
| `MQL5/Include/GoldEvidence/Filters.mqh` | 4432 | `4fade7a2b29ba8a024beb23b4c4d9521c0d533baad3f13537b141eb7bcab25a8` |
| `MQL5/Include/GoldEvidence/Journal.mqh` | 2601 | `99e0556da36b138cc2b37a2ce274f559115e346c0d8c19ac145968c294cf9e4b` |
| `MQL5/Include/GoldEvidence/Levels.mqh` | 6437 | `d04d1bbff1a36bfcb05e7ea8ed5f0b2da06afe9e4b1ce4e99f64ea231c0e7669` |
| `MQL5/Include/GoldEvidence/MarketData.mqh` | 4574 | `3ea07c16f052a626fdabd0731968a4f11afda381db5f3cf20ae39c115cc44d25` |
| `MQL5/Include/GoldEvidence/NewsFilter.mqh` | 4796 | `9dc1b5266f5acf0721ff113440c7c31b9c4154cb79c04aef736f30a25316958f` |
| `MQL5/Include/GoldEvidence/Risk.mqh` | 10277 | `9be3c5698194abb2c401bdebecbf42d2c96bafa9e515e3e17cd623c497b4a88a` |
| `MQL5/Include/GoldEvidence/Rules.mqh` | 9701 | `2731af29e63c0fab3825a2f59003ce7ac5dabedc2c812e99677883f556a6fccb` |
| `MQL5/Include/GoldEvidence/Structure.mqh` | 4456 | `27f21bde3134eb517bcf79751291b851a16cb48817412a946b06be3d9f795b2f` |
| `MQL5/Include/GoldEvidence/Types.mqh` | 3382 | `096775d0efe8a977b2a60674ec6bac14090cfb371a9a37fabdac77aace15e1d3` |
| `MQL5/Scripts/GoldEvidence/GE_DataAudit.mq5` | 8799 | `ca8622a9c0c7c69b244062dd7d09c07e25ad7d86de201314bd0eec05797ad02f` |
| `MQL5/Scripts/GoldEvidence/GE_ExportNews.mq5` | 2511 | `7b444331da3f7f2bf599aed350960d65e68e424307b377ef79b21bfe6c91abca` |
| `README.md` | 2389 | `9330339a0d8d0ced4148cd826ba014994993e86ce07c8eb62241e3df716d6910` |
| `ai_service/__init__.py` | 84 | `beb51edf5d3ca8adea7a0801dd1abac1f88265ea4e1e722790748dfc96b12aa0` |
| `ai_service/__main__.py` | 33 | `ddd60a1df996b2b744c45953165711e5afe2711f5f0249f4e98875e1342411df` |
| `ai_service/audit_log.py` | 872 | `766fdee26728e0bc2a1511787c197b1abc40a3f907449d8432d9c178a67da2e6` |
| `ai_service/budget.py` | 2922 | `62ce5f5461874649f7ec7759f5bb0485d44fd85787e10a604f421751f5c4914b` |
| `ai_service/claude_client.py` | 2953 | `ec8f9ec5899eb411dad9862214cb78f3ac6a041e3181056577b626664589bb4a` |
| `ai_service/config.py` | 3762 | `dd5c4eb4b6eefeeb4227763b6031220d85d808437ec177ef70b7cc6d0ec392c3` |
| `ai_service/prompt.py` | 4498 | `3a39e8cfad17e8551db792a901efc5c074aad3bc59268e98b7cf92adaacaca9b` |
| `ai_service/requirements.txt` | 143 | `7d07b74dc19646b89f291bb1b3dd31b5c0e46994f3aa60e258796bf27a54c0a0` |
| `ai_service/schemas.py` | 2913 | `b75fb6aee784dba0b309d045cc743fc9fca53d9842f36f9479042e1c4efdfbe7` |
| `ai_service/server.py` | 3506 | `df0adc74bab87bd6258a56bab6a0dcd5dbffed03f861497332031560f480a5e0` |
| `ai_service/service.py` | 3585 | `58f1ec4ef09027cf834d202aeb52ed199a58be1a8f09c6245b01667880320272` |
| `ai_service/tests/test_service.py` | 9397 | `6822dd954a05720153b787f3f482c4adcc5d8973246fe68ffd9c6cf5d415f911` |
| `ai_service/validation.py` | 2443 | `8ddb054edf7ece19a18b4dfa1e288bff30516824744530b3e33d6eef34539774` |
| `analysis/__init__.py` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `analysis/acceptance_criteria.json` | 603 | `dd5b7ef3d1ef07deb8b0287217536d5ecffb54d15319339a880a5af5e2bb477c` |
| `analysis/backtest_stats.py` | 14950 | `62c07b1cd05d78b9ed404afbd9375022a3681a4498a510886e2a1b25ac7c8b09` |
| `analysis/tests/test_stats.py` | 4277 | `311ce9739811f7335f33dfd9f9b6ae4d22ac8c952961c031e851ed5f3945323c` |
| `docs/INSTALL.md` | 5806 | `bff5084e51537a7c647a39ab18c27555be5ebc593e6ae80f14f7d9c7af9ebde9` |
| `docs/VALIDATION_PROTOCOL.md` | 4272 | `80aac5de4a8909b739c1cd9d9bade8758a936394ed1a8659aef8649e0597940a` |
