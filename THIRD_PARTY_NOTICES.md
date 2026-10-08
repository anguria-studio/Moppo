# Third-party notices

## Purge

Author: Jithin Sabu.
Source: https://github.com/jithin-sabu/purge-app.
Reference revision: `330d1fe09bb91ff521bcce1f4b01c26e80e724ae`.

Moppo uses the following material from this project:

- `Core/Sources/MoppoCore/Scan/IdentityState.swift` uses cache names, name fragments,
  and container identifiers from Purge's `purge/Services/DeletionSafetyPolicy.swift`.
  Moppo applies these lists with its own matching rules.
- Purge's `purge/Services/AIModelScanner.swift` informed the original Ollama manifest
  reader in `Core/Sources/MoppoCore/Scan/LocalModelStores.swift`.
  The current reader uses different shared-model grouping logic.

Other source comments identify design references where relevant.
These references do not mean that Moppo copied those complete implementations.

The following notice reproduces the upstream MIT license without changes.

```text
MIT License

Copyright (c) 2026 Jithin Sabu

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
