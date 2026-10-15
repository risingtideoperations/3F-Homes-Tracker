import json,os,urllib.request
html=open('3f-flip-tracker/web/index.html').read()
q="insert into flips.site_files(name,content,updated_at) values ('index.html', $pg$"+html+"$pg$, now()) on conflict (name) do update set content=excluded.content, updated_at=now() returning name, length(content)"
assert '$pg$' not in html
req=urllib.request.Request('https://api.supabase.com/v1/projects/csdsendpbnwycwhqwgbe/database/query',data=json.dumps({'query':q}).encode(),headers={'Authorization':'Bearer '+os.environ['SUPABASE_ACCESS_TOKEN'],'Content-Type':'application/json'},method='POST')
print(urllib.request.urlopen(req).read().decode())
