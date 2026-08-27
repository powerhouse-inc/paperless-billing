#!/usr/bin/env python3
"""One-shot bootstrap: wires Paperless to the reactor.

Runs as a docker-compose service (see the `bootstrap` service). Both Paperless
and the reactor are containers here, so every address is a service name on the
compose network; all four are supplied by the compose file. Idempotent — every
step checks before it writes, so re-running on every `docker compose up` is the
intended mode of operation.

What it ensures, in order:
  1. a Paperless document type "Invoice" that auto-assigns to documents
     containing the word "invoice" (matching_algorithm=1, Any word)
  2. a "Billing" drive (powerhouse/document-drive, preferredEditor "billing")
     on the reactor
  3. a "Paperless Connection" sync document inside that drive
  4. an enabled mapping Invoice -> powerhouse/invoice on the sync document,
     updated in place if the Paperless type id drifted (e.g. after `down -v`)
  5. the "Powerhouse push sync" workflow exists in Paperless; if Paperless was
     wiped but the sync document still says registered, re-request registration

Everything else (connection credentials, AI config, webhook secret, workflow
registration itself) is bootstrapped by the paperless-sync processor from the
reactor's environment — this script never sees those secrets.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid

PAPERLESS_URL = os.environ.get("BOOTSTRAP_PAPERLESS_URL", "http://webserver:8000").rstrip("/")
REACTOR_URL = os.environ.get("BOOTSTRAP_REACTOR_URL", "http://host.docker.internal:4001").rstrip("/")
ADMIN_USER = os.environ.get("PAPERLESS_ADMIN_USER", "admin")
ADMIN_PASSWORD = os.environ.get("PAPERLESS_ADMIN_PASSWORD", "paperless")
# The reactor runs on the host and is typically started separately from
# `docker compose up`, so wait generously before giving up.
REACTOR_WAIT_SECONDS = int(os.environ.get("BOOTSTRAP_REACTOR_WAIT_SECONDS", "300"))
# What the sync document should record as the Paperless URL — as seen from
# the host reactor, not from this container.
PAPERLESS_URL_FROM_REACTOR = os.environ.get("BOOTSTRAP_PAPERLESS_URL_FROM_REACTOR", "http://localhost:8000").rstrip("/")
SUBGRAPH_URL = os.environ.get("BOOTSTRAP_SUBGRAPH_URL", "http://host.docker.internal:4001/graphql/paperless-webhook")

DRIVE_NAME = "Billing"
DRIVE_SLUG = "billing"
DRIVE_PREFERRED_EDITOR = "billing"
SYNC_DOC_NAME = "Paperless Connection"
DOCTYPE_NAME = "Invoice"
TARGET_DOCUMENT_TYPE = "powerhouse/invoice"
WORKFLOW_NAME = "Powerhouse push sync"


def log(msg: str) -> None:
    print(f"[bootstrap] {msg}", flush=True)


def http(method: str, url: str, body=None, headers=None, timeout=15):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else {}


def gql(query: str, variables=None):
    """All queries go to the supergraph at /graphql, which federates every
    subgraph (DocumentDrive, PaperlessSync, ...) behind one endpoint."""
    out = http("POST", f"{REACTOR_URL}/graphql", {"query": query, "variables": variables or {}})
    if out.get("errors"):
        raise RuntimeError(f"GraphQL: {out['errors'][0].get('message')}")
    return out["data"]


def wait_for(name: str, probe, seconds: int) -> None:
    deadline = time.monotonic() + seconds
    while True:
        try:
            probe()
            log(f"{name} is up")
            return
        except urllib.error.HTTPError:
            # The server answered with an error status — it is up. (Paperless
            # returns 406 for the login redirect when Accept is JSON.)
            log(f"{name} is up")
            return
        except Exception as error:  # noqa: BLE001 - connection refused et al.
            if time.monotonic() >= deadline:
                raise SystemExit(f"[bootstrap] gave up waiting for {name}: {error}")
            time.sleep(3)


# ---------------------------------------------------------------- Paperless

def paperless_token() -> str:
    out = http("POST", f"{PAPERLESS_URL}/api/token/", {"username": ADMIN_USER, "password": ADMIN_PASSWORD})
    return out["token"]


def ensure_document_type(token: str) -> int:
    headers = {"Authorization": f"Token {token}"}
    listing = http("GET", f"{PAPERLESS_URL}/api/document_types/?page_size=100", headers=headers)
    for entry in listing.get("results", []):
        if entry["name"].lower() == DOCTYPE_NAME.lower():
            log(f'document type "{DOCTYPE_NAME}" exists (id={entry["id"]})')
            return entry["id"]
    created = http("POST", f"{PAPERLESS_URL}/api/document_types/", {
        "name": DOCTYPE_NAME,
        "match": "invoice",
        "matching_algorithm": 1,  # Any word
        "is_insensitive": True,
    }, headers=headers)
    log(f'created document type "{DOCTYPE_NAME}" (id={created["id"]}, matches any word "invoice")')
    return created["id"]


def workflow_exists(token: str) -> bool:
    headers = {"Authorization": f"Token {token}"}
    listing = http("GET", f"{PAPERLESS_URL}/api/workflows/", headers=headers)
    return any(w.get("name") == WORKFLOW_NAME for w in listing.get("results", []))


# ------------------------------------------------------------------ Reactor

def ensure_drive() -> str:
    data = gql("""
      { findDocuments(search:{type:"powerhouse/document-drive"}) { items { id name slug } } }""")
    for item in data["findDocuments"]["items"]:
        if item.get("slug") == DRIVE_SLUG:
            log(f'drive "{DRIVE_NAME}" exists (id={item["id"]})')
            return item["id"]
    data = gql("""
      mutation($name:String!,$slug:String,$editor:String) {
        DocumentDrive { createDocument(name:$name, slug:$slug, preferredEditor:$editor) { id } } }""",
        {"name": DRIVE_NAME, "slug": DRIVE_SLUG, "editor": DRIVE_PREFERRED_EDITOR})
    drive_id = data["DocumentDrive"]["createDocument"]["id"]
    log(f'created drive "{DRIVE_NAME}" (id={drive_id}, preferredEditor={DRIVE_PREFERRED_EDITOR})')
    return drive_id


def ensure_sync_document(drive_id: str) -> str:
    data = gql("""
      query($id:String!) {
        documentOutgoingRelationships(
          sourceIdentifier:$id, relationshipType:"child", paging:{limit:100}) {
            items { id name documentType } } }""", {"id": drive_id})
    for item in data["documentOutgoingRelationships"]["items"]:
        if item["documentType"] == "powerhouse/paperless-sync":
            log(f'sync document exists (id={item["id"]})')
            return item["id"]
    data = gql("""
      mutation($name:String!,$parent:String) {
        PaperlessSync { createDocument(name:$name, parentIdentifier:$parent) { id } } }""",
        {"name": SYNC_DOC_NAME, "parent": drive_id})
    doc_id = data["PaperlessSync"]["createDocument"]["id"]
    log(f'created sync document "{SYNC_DOC_NAME}" (id={doc_id}) in drive {drive_id}')
    return doc_id


def read_sync_state(doc_id: str):
    data = gql("""
      query($id:String!) {
        PaperlessSync { document(identifier:$id) { document { state { global {
          mappings { id paperlessTypeId targetDocumentType enabled }
          push { enabled subgraphUrl paperlessWorkflowId error }
          credentials { instanceUrl }
          connection { status }
        } } } } } }""", {"id": doc_id})
    return data["PaperlessSync"]["document"]["document"]["state"]["global"]


def ensure_connection(doc_id: str, token: str) -> None:
    """Local-dev convenience: the admin token is fetched from the dev instance,
    so .env never needs PAPERLESS_API_TOKEN. A connection that is already set
    (by the processor's own env bootstrap, or by hand) is left alone."""
    state = read_sync_state(doc_id)
    status = (state.get("connection") or {}).get("status")
    if state.get("credentials") and status != "FAILED":
        log(f"connection already set ({state['credentials']['instanceUrl']}, status={status})")
        return
    if status == "FAILED":
        log("recorded connection FAILED (stale token after a wipe?) — re-setting it")
    now = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
    gql("""
      mutation($doc:PHID!,$input:PaperlessSync_SetConnectionInput!) {
        PaperlessSync { setConnection(docId:$doc, input:$input) { id } } }""",
        {"doc": doc_id, "input": {"instanceUrl": PAPERLESS_URL_FROM_REACTOR, "apiToken": token}})
    gql("""
      mutation($doc:PHID!,$input:PaperlessSync_RequestConnectionTestInput!) {
        PaperlessSync { requestConnectionTest(docId:$doc, input:$input) { id } } }""",
        {"doc": doc_id, "input": {"requestedAt": now}})
    log(f"set connection to {PAPERLESS_URL_FROM_REACTOR} and requested a connection test")


def ensure_mapping(doc_id: str, paperless_type_id: int) -> None:
    state = read_sync_state(doc_id)
    existing = next((m for m in state["mappings"] if m["targetDocumentType"] == TARGET_DOCUMENT_TYPE), None)
    if existing is None:
        gql("""
          mutation($doc:PHID!,$input:PaperlessSync_AddMappingInput!) {
            PaperlessSync { addMapping(docId:$doc, input:$input) { id } } }""",
            {"doc": doc_id, "input": {
                "id": str(uuid.uuid4()),
                "paperlessTypeId": paperless_type_id,
                "paperlessTypeName": DOCTYPE_NAME,
                "targetDocumentType": TARGET_DOCUMENT_TYPE,
                "enabled": True,
            }})
        log(f"added mapping {DOCTYPE_NAME}(id={paperless_type_id}) -> {TARGET_DOCUMENT_TYPE}")
    elif existing["paperlessTypeId"] != paperless_type_id or not existing["enabled"]:
        gql("""
          mutation($doc:PHID!,$input:PaperlessSync_UpdateMappingInput!) {
            PaperlessSync { updateMapping(docId:$doc, input:$input) { id } } }""",
            {"doc": doc_id, "input": {
                "id": existing["id"],
                "paperlessTypeId": paperless_type_id,
                "paperlessTypeName": DOCTYPE_NAME,
                "enabled": True,
            }})
        log(f"updated mapping to {DOCTYPE_NAME}(id={paperless_type_id}) (was id={existing['paperlessTypeId']})")
    else:
        log("mapping is current")


def heal_push_registration(doc_id: str, token: str) -> None:
    """After `docker compose down -v` Paperless loses the workflow but the sync
    document still records a successful registration, so the processor will not
    re-register on its own. Detect that and re-request."""
    state = read_sync_state(doc_id)
    push = state.get("push")
    if not push or not push.get("subgraphUrl"):
        # The processor's one-shot env bootstrap ran before credentials
        # existed, or the env lacks the webhook settings. Now that the
        # connection is set, request registration ourselves.
        gql("""
          mutation($doc:PHID!,$input:PaperlessSync_RequestPushRegistrationInput!) {
            PaperlessSync { requestPushRegistration(docId:$doc, input:$input) { id } } }""",
            {"doc": doc_id, "input": {
                "subgraphUrl": SUBGRAPH_URL,
                "requestedAt": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
            }})
        log(f"requested push registration for {SUBGRAPH_URL}")
        for _ in range(10):
            if workflow_exists(token):
                log(f'workflow "{WORKFLOW_NAME}" registered')
                return
            time.sleep(3)
        log(f'WARNING: workflow "{WORKFLOW_NAME}" still absent — check the reactor log for [paperless-sync] errors')
        return
    for _ in range(10):  # the processor registers within a few seconds
        if workflow_exists(token):
            log(f'workflow "{WORKFLOW_NAME}" present in Paperless')
            return
        time.sleep(3)
    gql("""
      mutation($doc:PHID!,$input:PaperlessSync_RequestPushRegistrationInput!) {
        PaperlessSync { requestPushRegistration(docId:$doc, input:$input) { id } } }""",
        {"doc": doc_id, "input": {
            "subgraphUrl": push["subgraphUrl"],
            "requestedAt": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
        }})
    log("workflow was missing in Paperless; re-requested push registration")
    for _ in range(10):
        if workflow_exists(token):
            log(f'workflow "{WORKFLOW_NAME}" registered')
            return
        time.sleep(3)
    log(f'WARNING: workflow "{WORKFLOW_NAME}" still absent — check the vetra log for [paperless-sync] errors')


def main() -> None:
    wait_for("Paperless", lambda: http("GET", f"{PAPERLESS_URL}/api/", timeout=5), 120)
    token = paperless_token()
    doctype_id = ensure_document_type(token)

    wait_for("reactor", lambda: gql("{ PaperlessSync { documents { totalCount } } }"),
             REACTOR_WAIT_SECONDS)
    drive_id = ensure_drive()
    doc_id = ensure_sync_document(drive_id)
    ensure_connection(doc_id, token)
    ensure_mapping(doc_id, doctype_id)
    # Config bootstrap (credentials, AI, push) is asynchronous in the processor;
    # give it a moment before checking whether the workflow needs healing.
    time.sleep(5)
    heal_push_registration(doc_id, token)
    log("done")


if __name__ == "__main__":
    sys.exit(main())
