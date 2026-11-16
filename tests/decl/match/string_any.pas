program string_any;
begin
  ShowMessage('hello');   // match: '...' matches any string literal
  ShowMessage('');        // match
  ShowMessage(S);         // no match: not a literal
end.
