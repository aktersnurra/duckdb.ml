let run () =
  let owner = Unique.create () in
  Unique.use (borrow_ owner);
  Unique.close owner
