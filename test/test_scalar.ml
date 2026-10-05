open! Base
module S = Duckdb.Scalar
let () =
  assert (String.equal (S.name S.Int8) "TINYINT");
  assert (String.equal (S.name S.Float32) "FLOAT");
  Stdlib.print_endline "scalar: names=ok"
