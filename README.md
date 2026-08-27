# Paperless Billing

Paperless-ngx to Powerhouse Billing, in Docker, with one command.

Drop a PDF invoice into Paperless; it comes out the other side as a
`powerhouse/invoice` document in a Billing drive, with the fields extracted by
an LLM.

```bash
cp .env.example .env      # fill in PAPERLESS_AI_API_KEY
./start.sh
```

First run pulls ~2.6 GB and installs the reactor packages, so give it a few
minutes. After that, start-up is quick.


|             |                                                                        |
| ----------- | ---------------------------------------------------------------------- |
| Paperless   | [http://localhost:8000](http://localhost:8000) (`admin` / `paperless`) |
| Connect     | [http://localhost:3000](http://localhost:3000)                         |
| Reactor API | [http://localhost:4001/graphql](http://localhost:4001/graphql)         |


