# ci-smoke

A repository for checking a maccheri pool end to end: push → `workflow_job` webhook → control
plane → agent → throwaway VM → runner → green check → VM deleted.

The workflow (`.github/workflows/smoke.yml`) runs on `[self-hosted, maccheri]`, builds and tests a
tiny Swift package on an iOS simulator with `xcodebuild` and launches Settings with `xcrun simctl`,
uploading a screenshot.

```sh
cp -R guest/ci-smoke /tmp/maccheri-ci-smoke && cd /tmp/maccheri-ci-smoke
git init -b main && git add -A && git commit -m "maccheri smoke test"
# create an empty private repository on GitHub, install the team's GitHub App on it
# (guest/github-app/README.md), then:
git remote add origin git@github.com:<owner>/maccheri-ci-smoke.git && git push -u origin main
```

Later runs: Actions → maccheri smoke → Run workflow, or any push.
