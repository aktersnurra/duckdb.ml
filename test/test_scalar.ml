open! Base
module S = Duckdb.Scalar
let () =
  assert (Result.is_ok (S.validate S.Int8 (-128)));
  assert (Result.is_error (S.validate S.Int8 128));
  assert (Result.is_error (S.validate S.Int16 (-32769)));
  assert (Result.is_error (S.validate S.Float32 0.1));
  assert (Result.is_ok (S.validate S.Float32 (S.round_float32 0.1)));
  assert (Result.is_ok (S.validate S.Float32 Float.infinity));
  assert (Result.is_ok (S.validate S.Float32 Float.nan));
  assert (Int64.equal (Stdlib.Int64.bits_of_float (S.round_float32 (-0.))) Int64.min_value)
