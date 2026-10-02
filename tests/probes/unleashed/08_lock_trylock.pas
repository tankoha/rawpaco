{$mode unleashed}
program LockTryLock;
// concurrency: lock / trylock ... wait ... do ... else
uses Classes;
var
  total, n: Integer;
  cache, queue: TStringList;
  item: string;
begin
  lock(total) do total += n;
  trylock(cache) wait 50 do cache.Add(item) else queue.Add(item);
end.
