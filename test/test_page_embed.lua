-- The compiled-in copy of each WebView page must match www/app/index.html.
local ok = os.execute("luajit tools/embed-pages.lua --check")
if ok == true or ok == 0 then
  print("  ok   every embedded page matches its source")
  print("\n1 passed, 0 failed")
else
  print("  FAIL an embedded page is stale (run `make embed-pages`)")
  print("\n0 passed, 1 failed")
  os.exit(1)
end
