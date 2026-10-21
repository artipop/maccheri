# The GitHub App

One GitHub App per control plane does two jobs (`protocol/Sources/MaccheriProtocol/Teams.swift`):

- **Sign-in.** The web client signs users in with the App's OAuth (`/auth/github/login` →
  GitHub → `/auth/github/callback`). The control plane gets a user-to-server token and reads
  `GET /user` with it: id, login, name, avatar.
- **CI.** A team admin installs the App from the team's page (`/v1/teams/{id}/github/link`); GitHub
  redirects to `/github/setup` with the installation id and the state that names the team. From then
  on GitHub sends `workflow_job` webhooks for the installation's repositories. The control plane asks
  GitHub for a just-in-time runner config for the job's repository and hands it to an agent of that
  team. The agent boots a VM whose runner takes exactly that job.

The App is registered once, by whoever runs the control plane. Its private key, client secret and
webhook secret go only into the control plane's environment, never into a repository.

| What the App has | Why |
|---|---|
| Callback URL `https://<domain>/auth/github/callback` | OAuth sign-in |
| Setup URL `https://<domain>/github/setup`, also on update | binds an installation to a team |
| `request_oauth_on_install: false` | installing is not signing in; the setup URL gets the installation |
| Event `workflow_job`, webhook `https://<domain>/github/webhook` | a job wants `[self-hosted, maccheri]` |
| Repository permission Administration: write | `POST /repos/{owner}/{repo}/actions/runners/generate-jitconfig` |
| Repository permission Actions: read | delivering `workflow_job` |
| Metadata: read | mandatory for every App |
| Organization permission Self-hosted runners: write | only with `--org`; not used yet |

Sign-in needs no extra permission: a user-to-server token can always read the user's public profile
(`GET /user`). The email address would need the account permission "Email addresses: read", and the
contract does not use it.

## Registering

The control plane has to be deployed first: GitHub calls it back on its domain.

```sh
guest/github-app/register.sh <domain>                 # an App on your account
guest/github-app/register.sh <domain> --org <org>     # an App owned by an organisation
```

1. The script opens GitHub with the manifest (`manifest.json`) filled in. Check the name (it has to
   be unique on GitHub, `--name` changes it) and press **Create GitHub App**.
2. GitHub redirects to `http://localhost:8765/callback`, where the script waits, and the script
   exchanges the one-time code for the App's credentials. They land in
   `~/.maccheri/github-app-<slug>.json` (mode 600): `id`, `slug`, `client_id`, `client_secret`,
   `webhook_secret`, `pem`.
3. Put them into the control plane's environment, `deploy/.env` on the server:
   ```
   GITHUB_APP_ID=<id>
   GITHUB_APP_SLUG=<slug>
   GITHUB_CLIENT_ID=<client_id>
   GITHUB_CLIENT_SECRET=<client_secret>
   GITHUB_WEBHOOK_SECRET=<webhook_secret>
   GITHUB_APP_PRIVATE_KEY=<pem, the whole PEM with its newlines>
   ```
   `jq -r .pem ~/.maccheri/github-app-<slug>.json` prints the key; likewise `.client_secret` and
   `.webhook_secret`. The slug builds the install link `https://github.com/apps/<slug>/installations/new`.
4. Sign in to the web client with GitHub, create a team and install the App from the team's page on
   the repositories whose jobs the team's Macs should run. For the first run, the test repository from
   `guest/ci-smoke`. Installing from the App's GitHub page directly binds the installation to no team.

By hand, without the script: GitHub → Settings → Developer settings → GitHub Apps → New GitHub App,
with the URLs, permissions and event from the table above, a random webhook secret, "Only on this
account"; then generate a client secret and a private key on the App's page.

## Checking

- Sign-in: open the web client and sign in with GitHub. GitHub asks once to authorise the App.
- CI: push to the test repository (`guest/ci-smoke/README.md`). The App's page → Advanced →
  Recent deliveries shows each `workflow_job` delivery and the control plane's response; a 2xx means
  the job was queued.
