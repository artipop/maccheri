# The team's GitHub App

CI jobs reach the pool through a GitHub App: GitHub sends `workflow_job` webhooks to the control
plane, the control plane asks GitHub for a just-in-time runner config for the job's repository and
hands it to an agent, and the agent boots a VM whose runner takes exactly that job.

The App is registered once per team by its owner. Its private key and webhook secret go only to
the control plane's environment, never into a repository.

| What the App needs | Why |
|---|---|
| Event `workflow_job` | the control plane learns that a job wants `[self-hosted, maccheri]` |
| Repository permission Administration: write | `POST /repos/{owner}/{repo}/actions/runners/generate-jitconfig` |
| Repository permission Actions: read | delivering `workflow_job` |
| Metadata: read | mandatory for every App |
| Organization permission Self-hosted runners: write | only with `--org`; the control plane does not use it yet |

## Registering

The control plane has to be deployed first: the webhook URL is `https://<domain>/github/webhook`.

```sh
guest/github-app/register.sh <domain>                 # an App on your account
guest/github-app/register.sh <domain> --org <org>     # an App owned by an organisation
```

1. The script opens GitHub with the manifest (`manifest.json`) filled in. Check the name (it has to
   be unique on GitHub, `--name` changes it) and press **Create GitHub App**.
2. GitHub redirects to `http://localhost:8765/callback`, where the script waits, and the script
   exchanges the one-time code for the App's credentials. They land in
   `~/.maccheri/github-app-<slug>.json` (mode 600): `id`, `pem`, `webhook_secret`.
3. **Install** the App on the repositories whose jobs the pool should run (the script prints the
   link). For the first run, the test repository from `guest/ci-smoke`.
4. Give the control plane its environment (deploy/.env on the server):
   ```
   GITHUB_APP_ID=<id>
   GITHUB_WEBHOOK_SECRET=<webhook_secret>
   GITHUB_APP_PRIVATE_KEY=<pem, the whole PEM with its newlines>
   ```
   `jq -r .pem ~/.maccheri/github-app-<slug>.json` prints the key.

By hand, without the script: GitHub → Settings → Developer settings → GitHub Apps → New GitHub App,
with the webhook URL, a random webhook secret, the permissions and the event from the table above,
"Only on this account"; then generate a private key on the App's page.

## Checking

Push to the test repository (see `guest/ci-smoke/README.md`). The App's page → Advanced → Recent
deliveries shows each `workflow_job` delivery and the control plane's response; a 2xx means the job
was queued.
