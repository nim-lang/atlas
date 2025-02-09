
import asynchttpserver, asyncdispatch
import os, strutils, mimetypes

type
  GitRepo = object
    path: string
    name: string

var searchDirs: seq[string]

proc findDir(org, repo, files: string): string =
  {.cast(gcsafe).}:
    for folder in searchDirs:
      result = folder / org / repo / files
      if dirExists(folder / org / repo):
        break

proc handleRequest(req: Request) {.async.} =
  let arg = req.url.path.strip(chars={'/'})
  let dirs = arg.split('/')
  let org = dirs[0]
  let repo = dirs[1]
  let files = dirs[2..^1].join($DirSep)
  let path = findDir(org, repo, files)
  echo "http request: ", req.reqMethod, " repo: ", repo, " path: ", path

  # Serve static files if not a git request
  if fileExists(path):
    let ext = splitFile(path).ext
    var contentType = newMimetypes().getMimetype(ext.strip(chars={'.'}))
    if contentType == "": contentType = "application/octet-stream"
    
    var headers = newHttpHeaders()
    headers["Content-Type"] = contentType
    
    let content = readFile(path)
    await req.respond(Http200, content, headers)
  else:
    await req.respond(Http404, "File not found")

when isMainModule:

  let server = newAsyncHttpServer()
  let port = 8080
  
  for arg in commandLineParams():
    if dirExists(arg):
      searchDirs.add(arg.absolutePath)

  echo "Starting server on port ", port
  waitFor server.serve(Port(port), handleRequest)