# Publishing the VS Code extension

The release workflow packages five platform-specific VSIXs for `kksat.zals`.
Registry publication is separately opt-in: `publish_vscode` selects Visual Studio
Marketplace, and `publish_openvsx` selects Open VSX. Both jobs consume the complete
GitHub release only after its package metadata, bundled binaries, and
`SHA256SUMS` have been verified. They upload the existing VSIXs without rebuilding,
bumping versions, moving tags, or replacing GitHub assets.

Marketplace authentication defaults to `vscode_auth=entra`. To use the repository
secret `VSCE_PAT` instead, explicitly select `vscode_auth=pat`; there is no
implicit fallback from Entra to a PAT.

## Visual Studio Marketplace: one-time setup

We use the [secure automated publishing procedure](https://code.visualstudio.com/api/working-with-extensions/publishing-extension#secure-automated-publishing-to-visual-studio-marketplace):
Microsoft Entra ID, workload identity federation, and a user-assigned managed
identity. The linked example uses Azure Pipelines; here GitHub Actions supplies
OIDC tokens through [`azure/login`](https://github.com/Azure/login#login-with-openid-connect-oidc-recommended),
and `vsce publish --azure-credential` uses the resulting Azure CLI session.
**No Azure DevOps PAT or client secret is stored in GitHub.**

1. Create or confirm the Marketplace publisher ID **`kksat`** at
   <https://marketplace.visualstudio.com/manage>.
2. In Azure, create a **user-assigned managed identity** dedicated to publishing.
   Assign the **Reader** role as in Microsoft's procedure, scoped to the
   subscription used for login. Record its **client ID**, **tenant ID**, and
   **subscription ID**. Azure Reader access does not itself grant Marketplace
   publishing rights.
3. In this GitHub repository, create the environment **`vscode-marketplace`**.
   Restrict its deployment branches to **`main`** (the workflow dispatch ref,
   not the release tag); add required reviewers if available. This is important:
   the federated subject identifies the environment, not a particular branch.
4. Add a federated credential to the Azure managed identity with:

   | Field | Value |
   | --- | --- |
   | Issuer | `https://token.actions.githubusercontent.com` |
   | Subject | `repo:kksat/zals:environment:vscode-marketplace` |
   | Audience | `api://AzureADTokenExchange` |

   Use the actual GitHub owner/repository in the subject if this workflow is
   installed in a fork. For the Azure portal's GitHub credential form, select
   entity type **Environment**, with name `vscode-marketplace`. Do not select
   branch or tag. An Azure DevOps service connection is not needed for GitHub
   Actions. Do not select `auth-type: IDENTITY` in `azure/login`: that mode uses
   an Azure-hosted runner's identity endpoint rather than GitHub federation.
5. Add these **GitHub environment variables** (not secrets) to
   `vscode-marketplace`; repository variables also work:

   - `AZURE_CLIENT_ID`: the managed identity's client ID
   - `AZURE_TENANT_ID`: its tenant ID
   - `AZURE_SUBSCRIPTION_ID`: the subscription used for Azure login

6. Retrieve the managed identity's Marketplace profile ID once, as described in
   Microsoft's procedure. Run this command in an Azure CLI session authenticated
   **as the managed identity**, not as your personal account. One way is a
   temporary, manually dispatched GitHub job using the same environment,
   `id-token: write`, and `azure/login@v2` inputs as `vscode_marketplace`:

   ```sh
   az rest \
     --url https://app.vssps.visualstudio.com/_apis/profile/profiles/me \
     --resource 499b84ac-1321-427f-aa17-267ca6975798 \
     --query id --output tsv
   ```

   Remove the temporary job after setup. This returned `id` is the Marketplace
   profile ID: it is **not** the Azure ARM resource path, client ID, or principal
   object ID. Do not print access tokens to workflow logs.
7. In Marketplace publisher management, add that identity to `kksat` with the
   **Contributor** role. The identity must be authorized before the first upload.

## Visual Studio Marketplace: optional PAT setup

If explicitly selecting `vscode_auth=pat`, store an Azure DevOps PAT as the
repository secret **`VSCE_PAT`**. The token needs **Marketplace: Manage** scope,
**All accessible organizations**, and an account authorized to publish as
`kksat`. The PAT job does not need Azure ID variables, the
`vscode-marketplace` environment, or OIDC permissions. It exposes the PAT only
to the credential check and publishing step, not dependency installation.

Entra remains the recommended default. Microsoft's publishing guide notes that
global Azure DevOps PATs retire on December 1, 2026; treat this mode as a
transition path, not a replacement for setting up identity-based publishing.

## Open VSX: one-time setup

1. Sign in at <https://open-vsx.org> and accept the Open VSX publisher agreement.
2. Create or confirm the **`kksat`** namespace and ensure your token's account can
   publish to it. With the locked CLI installed, a namespace can be created once
   from `editors/vscode` using `npx --no-install ovsx create-namespace kksat` with
   `OVSX_PAT` provided securely in the environment.
3. Store the access token as the repository secret **`OVSX_PAT`**. It is passed
   only to the credential check and publishing step, not dependency installation.

The workflow does not create publishers/namespaces or change their membership.

## Publish an existing GitHub release

After the workflow change is on `main` and setup is complete:

```sh
gh workflow run release.yml --ref main -f tag=v0.1.0 \
  -f publish_existing=true -f publish_vscode=true -f publish_openvsx=true
```

To use the two repository PAT secrets instead of Entra:

```sh
gh workflow run release.yml --ref main -f tag=v0.1.0 \
  -f publish_existing=true -f publish_vscode=true -f vscode_auth=pat \
  -f publish_openvsx=true
```

Select either registry independently by omitting the other flag. For example,
Open VSX can be published before Azure setup is complete:

```sh
gh workflow run release.yml --ref main -f tag=v0.1.0 \
  -f publish_existing=true -f publish_openvsx=true
```

Omit `publish_existing` to build and publish in one run. Release-triggered runs
still publish only to GitHub; credentials alone never enable registry jobs.

Both clients are locked npm dependencies installed from the workflow revision,
so publishing an older tag can use updated tooling without altering its VSIXs.
Both use `--skip-duplicate` to allow retries after partial success. A duplicate
is skipped, not replaced; this does not compare registry bytes with GitHub bytes.
Adding a missing target platform does not require a version bump: Marketplace
identifies each package by version **and** target platform. For example, if only
`0.1.0/darwin-arm64` exists, the other four targets can be uploaded at `0.1.0`.
The existing target is skipped and kept unchanged. Changing its contents requires
a newer version; `--skip-duplicate` does not update that package.

Other upload/authentication failures fail the job. The registries run
independently, so a failure in one does not undo publication to the other.

Check the Actions run and registry pages after publishing:

- <https://marketplace.visualstudio.com/items?itemName=kksat.zals>
- <https://open-vsx.org/extension/kksat/zals>

Users receive the VSIX for their VS Code host platform, including remote hosts.
The five supported targets remain Linux x64/arm64, macOS x64/arm64, and Windows
x64; publication does not add support for other architectures.
