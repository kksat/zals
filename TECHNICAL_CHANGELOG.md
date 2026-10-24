# Changelog

## [0.3.0](https://github.com/kksat/zals/compare/v0.2.0...v0.3.0) (2026-10-24)


### Features

* **release:** gate initial publication on approved curated notes ([3e56128](https://github.com/kksat/zals/commit/3e561281ec002647b1d3d5ac432ad5ded27f81f5))
* **release:** separate public and technical changelogs ([e856f77](https://github.com/kksat/zals/commit/e856f77da63720ec31d84bc1f44b1f1dcbe642f0))
* **release:** validate curated notes and reviewed candidate coverage ([ca4128b](https://github.com/kksat/zals/commit/ca4128b9f93cf1bec0f72d946c8b1bf8d283a40e))


### Bug Fixes

* **navigation:** treat FQCN import_playbook as a playbook import ([c8f3ce6](https://github.com/kksat/zals/commit/c8f3ce6ac5cd5bacaef813161337cd7e217d9109))
* **release:** allow reviewed coverage-only notes refreshes ([c93bdbd](https://github.com/kksat/zals/commit/c93bdbd26cbe600fa2ae9fa712ff925a3b060753))
* **release:** bind published tags to approved candidate commits ([c0445f5](https://github.com/kksat/zals/commit/c0445f5f480efd7c8fa596cc048edff5cde7303f))
* **release:** mark ordinary PR readiness without bypassing bot gates ([ed5e16f](https://github.com/kksat/zals/commit/ed5e16fb92c3330f5306299e05923ae3e62ca150))
* **release:** preserve component-prefixed publication retries ([d8ed8b9](https://github.com/kksat/zals/commit/d8ed8b98bf5ad86dd889f858ee00637a99b7d97c))
* **release:** recover component-prefixed release tags ([ef2f757](https://github.com/kksat/zals/commit/ef2f75718e2fb8369749e793cb0bb8087b7ea5d3))
* **release:** refresh bot PR branches before readiness validation ([4274555](https://github.com/kksat/zals/commit/4274555c1d116f78a433d931d8a21e9b42ab3799))
* **release:** refuse to rewrite existing release prose ([16e3c48](https://github.com/kksat/zals/commit/16e3c485f35ce621ca730b4af45add4c60f12f7e))
* **release:** reject unresolved draft publication targets ([e57be60](https://github.com/kksat/zals/commit/e57be60ee59fcd16b8b3feef93a4ff3a7d10de64))
* **release:** require approval before the notes PR merge ([524c840](https://github.com/kksat/zals/commit/524c84031d43d5aefd0dfedc16f3b0f345a6b28b))
* **release:** skip uploads for identical published assets ([59b8d14](https://github.com/kksat/zals/commit/59b8d1456836a2baa1c063b58ead33fcfb0b65cc))
* **release:** upload recovery assets without rewriting release prose ([e4aea88](https://github.com/kksat/zals/commit/e4aea88ad0a2d8fa8d932696ef5cea67a253aeb0))
* **release:** validate the canonical VSIX changelog asset ([765184a](https://github.com/kksat/zals/commit/765184a2c101ef3de80a0a161c2f0d0b72c517cb))
* **symbols:** detect role handler files relative to the role root ([2f4bb06](https://github.com/kksat/zals/commit/2f4bb0682ca4d381d2d9f0559c906224fce62f68))
* **symbols:** label tasks in handler blocks as handlers ([4c63ae0](https://github.com/kksat/zals/commit/4c63ae020bb99921bba2456bf557119be1b9a983))
* **variables:** bind top-level keys only in Variable files ([f9f50fe](https://github.com/kksat/zals/commit/f9f50fed6b8dd569f570941d6415b01dff58adf9))
* **variables:** stop binding import_playbook vars in the importing playbook ([18f755d](https://github.com/kksat/zals/commit/18f755d5442d2e206c4e33835cc59ce15787b313))
* **workspace:** match open documents opened through a symlinked folder ([e88d5a3](https://github.com/kksat/zals/commit/e88d5a335b9cc6b8b8aa63897758ecd0336ec358))
* **workspace:** rescan once when the root marker changes ([88a6dc0](https://github.com/kksat/zals/commit/88a6dc01c5d7c932c345b4f445fb7179c65fe7d4))

## [0.2.0](https://github.com/kksat/zals/compare/zals-v0.1.0...zals-v0.2.0) (2026-10-16)


### Features

* add workspace ([e34846f](https://github.com/kksat/zals/commit/e34846f2e64cd445dba59b4aaeb5deeca73e2b4a))
* allow a configurable workspace root marker ([57847c1](https://github.com/kksat/zals/commit/57847c127bf832e47a679b74fceae421b89fce97))
* **code-actions:** add and remove debug statements for variables ([ec23358](https://github.com/kksat/zals/commit/ec2335897b70dad0a94055a4aa66c6c472e1635d))
* **code-actions:** extract tasks to a task file ([1405b3f](https://github.com/kksat/zals/commit/1405b3f75da1240d6d54c2190f8eb381d1a4ba04))
* **code-actions:** surround debug tasks with blank lines ([3755dd3](https://github.com/kksat/zals/commit/3755dd371a3bd12805929a776e1eb5f6a664ddf5))
* **collections:** navigate collection references ([9f70c43](https://github.com/kksat/zals/commit/9f70c4345239c3c1eb36e163919e9282422cccab))
* **config:** resolve role and collection paths per file ([6d01ef9](https://github.com/kksat/zals/commit/6d01ef9de53b0986fea82c332403fccd5dfc6035))
* **cursor:** classify a document position once for hover, completion, and tokens ([73abec5](https://github.com/kksat/zals/commit/73abec5c5039964f9ec705470644b7a1f5dd0d5c))
* **docs:** background prefetch, on-disk cache, and thread pool ([94e6681](https://github.com/kksat/zals/commit/94e6681d3d4c4c4cd33cc5a0dd920742bc0facdb))
* **document-symbols:** semantic outline for Ansible documents ([3384b28](https://github.com/kksat/zals/commit/3384b28d46bf94502580d0a604be8cce69e50143))
* **navigation:** navigate task files and vars files ([a702577](https://github.com/kksat/zals/commit/a7025775ac09980ea7e0e1c3223e6067e4220502))
* **navigation:** resolve concrete variable implementations ([2ae4bbb](https://github.com/kksat/zals/commit/2ae4bbb611f47f17a548b895d01f9b2ecfe9fa1a))
* **navigation:** resolve fields by name and parsed keys ([9cb40b6](https://github.com/kksat/zals/commit/9cb40b6402619ef9ae8e630889b942a0fa46d87f))
* **navigation:** resolve passed fields in callee path context ([448adf3](https://github.com/kksat/zals/commit/448adf37db7fd4f43ebe0f8d2278141f960a7939))
* **parity:** reach &gt;=0.9 on all comparison cases ([448e32e](https://github.com/kksat/zals/commit/448e32e9b40b742d05efe71df50eca5988fcde82))
* recognize static quoted Jinja field subscripts ([da9561e](https://github.com/kksat/zals/commit/da9561e45ddba80cbc0dce5c41ddcb1c03cca9e5))
* **release:** add release-please, cross-platform binaries, Homebrew, and PyPI ([06703e1](https://github.com/kksat/zals/commit/06703e1bdd7044f90f9ab75f7b9f9a1656a542c6))
* **release:** publish VSIXs to Marketplace and Open VSX ([3007350](https://github.com/kksat/zals/commit/30073506c2288301f8e98ed0e7f1680a42cdac1b))
* **release:** support explicit Marketplace PAT publishing ([7171059](https://github.com/kksat/zals/commit/7171059705b0f4e7a9b77846f7f8c6ff7f83006b))
* **roles:** find role references across the Workspace and hover roles ([c9bdbac](https://github.com/kksat/zals/commit/c9bdbac3cf9f64931391f4e91fa0d8fd099306bb))
* **roles:** go-to-definition and go-to-implementation for roles ([3925efe](https://github.com/kksat/zals/commit/3925efe034257cd8cf9d76af4c741f5af2f62ceb))
* **roles:** hover role parameters with their argument spec ([e383036](https://github.com/kksat/zals/commit/e383036e534b522564e75b4d9c5eea6dfb98069f))
* **roles:** resolve roles in Ansible's search order ([63d70ee](https://github.com/kksat/zals/commit/63d70eee68a5290cfcd6ec91e722c6b2dbbe75eb))
* **schema:** support JSON Schema pattern via in-tree regex engine ([3cf86b2](https://github.com/kksat/zals/commit/3cf86b2f37d619bd591da9a3ac121586351c410f))
* **symbols:** search Workspace symbols ([c777dde](https://github.com/kksat/zals/commit/c777dde46b2c7628882ffb3f08d6aef9a845f8c9))
* v1 implementation ([c7c984d](https://github.com/kksat/zals/commit/c7c984d5df1a91643be78af3c0b25581000ef1a9))
* **variables:** find references and go-to-definition for variables ([4b3b7e1](https://github.com/kksat/zals/commit/4b3b7e1c602e519f5ee92f5110b72817230d3958))
* **variables:** find variable references and definitions across the Workspace ([9d40205](https://github.com/kksat/zals/commit/9d40205201b7bdf617c748ded3ff53ea58f1bfdb))
* **variables:** hover variables with their active definition ([e599740](https://github.com/kksat/zals/commit/e5997404415e53acf17483e5ae304fb4cf97b6cd))
* **vscode:** add Zig ember extension icon ([a1c1927](https://github.com/kksat/zals/commit/a1c1927c4fa18b0e1c1a14ec61b34a85c5934a4f))
* **vscode:** integrate bundled extension for 0.1.0 packaging ([6da07ce](https://github.com/kksat/zals/commit/6da07ce36977606d6b2d8a802cda953f0a82d625))
* **workspace:** discover the Ansible files of a Workspace ([3f88f20](https://github.com/kksat/zals/commit/3f88f201ced18628d210a2890a19983bf1b2bc20))
* **workspace:** expose collection module and plugin symbols ([eecb5b8](https://github.com/kksat/zals/commit/eecb5b86422a48e67a39dae1edc5baf48959f3fb))
* **workspace:** keep a persistent Workspace index ([cc4ec1e](https://github.com/kksat/zals/commit/cc4ec1e84394d22c75819773c7f98591f1f2e107))
* **yaml:** add tree-sitter-yaml backend behind YamlParser seam ([8ffe557](https://github.com/kksat/zals/commit/8ffe557961ac1d1f1a81900bd54a98ae3b29ddb4))


### Bug Fixes

* **collections:** normalize direct ansible_collections search paths ([f1eb2d9](https://github.com/kksat/zals/commit/f1eb2d97c4d62e529159cd03abb489df5c209963))
* **collections:** search all selected venv installation layouts ([c6a5bca](https://github.com/kksat/zals/commit/c6a5bca99d5ddfa0f09e9bf9738215826de58965))
* **docs:** isolate module lookup by effective per-file collection paths ([20ed5b4](https://github.com/kksat/zals/commit/20ed5b459908ba6009dd71730006d5f199a52f62))
* **docs:** run ansible-doc without a per-file cwd or ansible.cfg ([c83ae0a](https://github.com/kksat/zals/commit/c83ae0ad85276de099f765440501c6b5f9ba655c))
* exclude called Jinja methods from field reads ([50b19d2](https://github.com/kksat/zals/commit/50b19d281f13e1c1e0538ba5a21a5aa15b421a69))
* exclude Jinja template filter-block names from navigation ([5cba024](https://github.com/kksat/zals/commit/5cba0242ada8215ff6cf1121e27c60abeda0043a))
* exclude qualified Jinja filter and test names from fields ([d10f3e2](https://github.com/kksat/zals/commit/d10f3e21494b923a5142612c071f2a9698db43a4))
* **homebrew:** capture version output in formula test ([a737371](https://github.com/kksat/zals/commit/a73737174fa627f1a9e275b2e96052c8db0f5676))
* ignore escaped single-quoted Jinja field lookalikes ([d330e30](https://github.com/kksat/zals/commit/d330e30040b525317eb0b2237f2d22207d00044d))
* ignore quoted Jinja closing delimiters ([d489063](https://github.com/kksat/zals/commit/d489063ca36b2d634f2ad9c911c7c98954bafc26))
* **lsp:** enforce queued writer ownership for outgoing messages ([77b9cda](https://github.com/kksat/zals/commit/77b9cda1524b57238fe3b5f817c7551d252d91fe))
* **navigation:** escape file URI paths and decode targets once ([18d0fb0](https://github.com/kksat/zals/commit/18d0fb01f051a0fa561c9744c001848c30ef57c9))
* **navigation:** exclude Jinja set field targets from reads ([a738e8a](https://github.com/kksat/zals/commit/a738e8a80f0971946d431cc9da48d7c1928b958e))
* **navigation:** exclude quotes from escaped binding ranges ([be72339](https://github.com/kksat/zals/commit/be7233976095e342038a52e8187d9377e99e153a))
* **navigation:** exclude raw-block literals from field reads ([48648c6](https://github.com/kksat/zals/commit/48648c6742507064f6aca5f5600e261dc451a68a))
* **navigation:** honor Jinja whitespace preservation markers ([b287931](https://github.com/kksat/zals/commit/b287931d97b774d2292f5c1326cc1b3a6196d195))
* **navigation:** make relative filesystem targets absolute file URIs ([181d11a](https://github.com/kksat/zals/commit/181d11a38d5d78f0915aab66b3747377b37c4dd6))
* **navigation:** match role references by resolved targets ([dc8e47e](https://github.com/kksat/zals/commit/dc8e47e0a5b4f6a2b68f7767c96dbdb849640e92))
* **navigation:** normalize YAML scalar quoting with source spans ([5a873ed](https://github.com/kksat/zals/commit/5a873edb3b71861b42d6ad7c6891c755ac98b967))
* **navigation:** preserve standalone role scope and variable precedence ([8b2548c](https://github.com/kksat/zals/commit/8b2548c27c0087efa2663060560c9d6dd9f18642))
* **navigation:** rank loaded vars by their source ([7e407ad](https://github.com/kksat/zals/commit/7e407ade973fbba409c47666af65342e706c8633))
* **navigation:** resolve passed role parameters in callee context ([ce2470a](https://github.com/kksat/zals/commit/ce2470a6af4c8ea3faca5c1a9ee055e6968c8e4b))
* **navigation:** resolve variable definitions from binding keys ([317b4ba](https://github.com/kksat/zals/commit/317b4bafa5ec56c64c5e64194d8c35288af0a33a))
* **navigation:** resolve variable loads like file links ([4cb0582](https://github.com/kksat/zals/commit/4cb0582d74f83a441562e839d0d043e0e9045477))
* **navigation:** resolve variable role invokers by directory ([c71f1dc](https://github.com/kksat/zals/commit/c71f1dc09cef4485a3b182e960f2579ded11e698))
* **navigation:** retain explicit JSON callee vars loads ([7f6f519](https://github.com/kksat/zals/commit/7f6f519d94714c8cb0f2ff8ae47521bebb1b7a37))
* **neovim:** attach zals to collection variable files ([d69b446](https://github.com/kksat/zals/commit/d69b446a3ad533b7d5ba7f80c6a381395d6187bb))
* **neovim:** detect standalone role repositories ([cff2140](https://github.com/kksat/zals/commit/cff2140314362e5ed86251cb1de89dc6ae9755f0))
* **perf:** clear Darwin override before launching nested make ([f2b96a8](https://github.com/kksat/zals/commit/f2b96a87ad8784ac103ae59a2a1831b2cf95e01d))
* **performance:** attest a narrow pinned baseline build repair ([71b2ed2](https://github.com/kksat/zals/commit/71b2ed24aaae1f316d2cc4b7f0882837680d5659))
* preserve keyword-like Jinja member names ([dfc68bc](https://github.com/kksat/zals/commit/dfc68bccf6f8403d62c35f0ce7eaa779e70573c1))
* **pypi:** replace invalid classifier without changing released binaries ([f59c099](https://github.com/kksat/zals/commit/f59c09969faa6a0adc9411816e3582ca23583178))
* **queries:** bound callee entry sorting to role directory ([9e685f6](https://github.com/kksat/zals/commit/9e685f6dd479f889f3888990902df755439db6f3))
* **release:** ignore comments when validating rendered formula ([da60053](https://github.com/kksat/zals/commit/da6005306b290ef56a7547bd40ba1504b7441102))
* **release:** publish only after release-please creates a release ([3c38367](https://github.com/kksat/zals/commit/3c38367e92ba63691f758834f9a723d224d63629))
* **shutdown:** cancel and reap in-flight documentation subprocesses ([0038b02](https://github.com/kksat/zals/commit/0038b02f6533eddc7e70ec82cac8719e51160456))
* **test:** retain server crash diagnostics through benchmark cleanup ([5980a98](https://github.com/kksat/zals/commit/5980a986bdbbd4191933291e0392abcfeea43ac3))
* **validation:** syntax-check when enabled lint is unavailable ([d0e96e7](https://github.com/kksat/zals/commit/d0e96e78c19b5c8708ea5bb281fe59dc13d22cbc))
* **variables:** distinguish structured data from binding scopes ([8f63342](https://github.com/kksat/zals/commit/8f6334286178c68e8b5c951ca21fc0b3fea2b06c))
* **variables:** exclude data keys from vars-file loads ([db90ff4](https://github.com/kksat/zals/commit/db90ff4634b49ef07b5b69522e35672f8b826bb0))
* **workspace:** lease indexed facts throughout query requests ([e387a82](https://github.com/kksat/zals/commit/e387a825bdebfd9fe7e6e0984efd42f3daad834c))
* **workspace:** prefer yaml main tasks for role symbol targets ([2505829](https://github.com/kksat/zals/commit/2505829da91aa236b9bb23459abd8d413619ab16))
* **workspace:** resolve metadata-defined collection role roots ([61fa974](https://github.com/kksat/zals/commit/61fa974e74f5d073ff07dc5e2c8d5f0ff468772b))
* **yaml:** prototype the external scanner constructor ([c067a7e](https://github.com/kksat/zals/commit/c067a7eb75abb6e571955a5d64282a98bc12feae))
* **yaml:** select cursor paths within parsed documents ([036ef1c](https://github.com/kksat/zals/commit/036ef1cab3964a9513865cd1e34e6f0c863c62ff))


### Performance Improvements

* **build:** optimize vendored parser in debug builds ([58cb5ca](https://github.com/kksat/zals/commit/58cb5cada844a63412e419d694db563b2627dd9b))
* **docs:** store module options as arena slices and deduplicate context libraries ([6cb28b1](https://github.com/kksat/zals/commit/6cb28b1c1fe55522f0ff8650c44a67ed281d5db7))
* **index:** allocate fact extraction scratch in temporary arena and intern entry strings ([a8fc6b4](https://github.com/kksat/zals/commit/a8fc6b4171497230ceb5f9b40b7a7fec3ee37783))
* **index:** release temporary file and parser storage ([1b56b94](https://github.com/kksat/zals/commit/1b56b9412fb456b233328afbd6fc0883ea274b0a))
* **index:** share cold parsing across bounded pool workers ([1c68c84](https://github.com/kksat/zals/commit/1c68c848f0d232ab6db7c34dae411114452ae72c))
* **lsp:** transfer serialized response buffers to writer and stream docs cache encoding ([d36a147](https://github.com/kksat/zals/commit/d36a1470542db1539ca97e39338641d43ec14aaa))
* **lsp:** unblock cold navigation during docs bootstrap ([38ca5fc](https://github.com/kksat/zals/commit/38ca5fc699baf4df38c3e72e97b60051c3c7f2ce))
* **memory:** avoid page_allocator churn in schema and description queries and use c_allocator in release ([e480c6b](https://github.com/kksat/zals/commit/e480c6b34e3c5e87fa93000e951d3b82ede80e12))
* **navigation:** avoid copying file text and rebuilding line tables per location ([79ddd08](https://github.com/kksat/zals/commit/79ddd0824672adada3bbe303c0c8abe1b0f58012))
* **roles:** reuse workspace view and collections in role resolution ([f2602f0](https://github.com/kksat/zals/commit/f2602f0fbe8780c244e05fa2a014dd45f5fa4799))
* **workspace:** defer lease refresh until indexed facts are borrowed ([a6bea14](https://github.com/kksat/zals/commit/a6bea14c6273913744933c75e21702aa3819c17a))
* **yaml:** reuse traversal path stack and avoid redundant variable scans and scalar copies ([1b61dd6](https://github.com/kksat/zals/commit/1b61dd6629af1c565bf14003ddc31f21dc461736))

## [0.1.0](https://github.com/kksat/zals/releases/tag/v0.1.0) (2026-09-19)

### Features

* initial release: stdio LSP server with semantic tokens, hover, completion,
  go-to-definition, find-references, and validation
