# Paperless Billing

Paperless-ngx to Powerhouse Billing, in Docker, with one command.

Drop a PDF invoice into Paperless; it comes out the other side as a
`powerhouse/invoice` document in a Billing drive, with the fields extracted by
an LLM.

```bash
cp .env.example .env      # fill in PAPERLESS_AI_API_KEY
./start.sh                # macOS, Linux, or WSL2
```

On **Windows without WSL**, use PowerShell instead — same checks, same output:

```powershell
Copy-Item .env.example .env   # fill in PAPERLESS_AI_API_KEY
.\start.ps1
```

Either script is only a wrapper: it loads `.env`, checks Docker and your API
key, runs `docker compose up -d --wait`, asserts the reactor actually loaded the
invoice model, and opens the browser. `docker compose up -d --wait` on its own
works anywhere — you just lose those checks.

First run pulls ~2.6 GB and installs the reactor packages, so give it a few  
minutes. After that, start-up is quick.



### Where to access services:


| Services    | Endpoints                                                                             |
| ----------- | ------------------------------------------------------------------------------------- |
| Paperless   | [http://localhost:8000](http://localhost:8000) Login details: (`admin` / `paperless`) |
| Connect     | [http://localhost:3000](http://localhost:3000)                                        |
| Reactor API | [http://localhost:4001/graphql](http://localhost:4001/graphql)                        |


