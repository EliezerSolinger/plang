import <httpd/httpd.psc> as httpd
r = httpd.json({"quem": "pscript", "quantos": 3})
print(str(r.body))
