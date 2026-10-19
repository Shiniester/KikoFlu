# OpenCC dictionaries

The unmodified `STPhrases.txt`, `STCharacters.txt`, `TSPhrases.txt`, and
`TSCharacters.txt` files come from [OpenCC 1.1.9](https://github.com/BYVoid/OpenCC/tree/ver.1.1.9/data/dictionary).
They are distributed under the included Apache-2.0 license.
OpenCC is maintained by Carbo Kuo and the [OpenCC contributors](https://github.com/BYVoid/OpenCC/blob/ver.1.1.9/AUTHORS).

The local Dart converter uses longest phrase matching followed by character
conversion, taking the first listed candidate. These are the dictionaries in
OpenCC's standard `s2t` and `t2s` configurations; regional vocabulary dictionaries
are not included. Upstream files are preserved so that dictionary updates do not
require maintaining individual character mappings.
