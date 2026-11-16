program create_assign;
var L, M: TObject;
begin
  L := TStringList.Create;      // match
  m := tstringlist.create;      // match: identifiers are case-insensitive
  L := { note } TStringList.Create; // match: comments are ignored
  L := TList.Create;            // no match: other class
  L := TStringList.Create(nil); // no match: argument list differs
end.
