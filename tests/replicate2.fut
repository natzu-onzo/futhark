-- Replicate with an unsigned type where zero-extension is important.
--
-- ==
-- input { 128u8 }
-- output { [42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32,
--           42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32,
--           42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32,
--           42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32,
--           42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32,
--           42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32,
--           42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32,
--           42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32,
--           42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32,
--           42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32,
--           42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32,
--           42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32,
--           42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32,
--           42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32,
--           42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32,
--           42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32, 42i32] }

import "/futlib/math"

let main(n: u8): []i32 =
  u8.replicate n 42
