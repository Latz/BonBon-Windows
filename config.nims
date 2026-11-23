switch("threads", "on")
switch("mm", "orc")
switch("path", thisDir() & "/src")
switch("warning", "Deprecated:off")
if projectName() == "bonbon":
  switch("app", "gui")
  switch("define", "release")
  switch("opt", "speed")
switch("define", "noRes")
