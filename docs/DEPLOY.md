# Развёртывание Gemoon

Инструкция для того, кто запускает деплой и апгрейды. Что делают контракты, описано в `README.md`.

## 1. Перед запуском

**Окружение.** Foundry установлен, `forge build` проходит. Переменные окружения лежат в `env/<ENVIRONMENT>.mk`: `env/dev.mk` (девнет) и `env/prod.mk`
(mainnet), оба не коммитятся. Окружение выбирается обязательной переменной `ENVIRONMENT=dev|prod`:
`make <цель> ENVIRONMENT=dev`, `ENVIRONMENT=prod ./deploy.sh`. Без неё или с другим значением
Makefile и скрипты из `tools/scripts` падают с ошибкой. Без `ENVIRONMENT` работают только `clean`,
`compile` и `unit-tests`; `prepare-abi` берёт адреса для README ABI из `env/<ENVIRONMENT>.mk`. Для prod Makefile дополнительно требует непустые
`GEMOON_OWNER` и `GEMOON_PROXY_ADMIN_OWNER`, деплоер как владелец по умолчанию там не подставляется.
Формат файлов: строки `KEY=VALUE` без кавычек и `$`, их читают и make, и bash. Файла `.env` быть не
должно: forge подгружает его сам, и значения из него попали бы в любое окружение.
Пустое значение считается незаданным.

| Переменная | Обязательна | Что это |
|---|---|---|
| `RPC` | да | RPC целевой сети |
| `PRIVATE_KEY` | да | ключ деплоера, с него уходят все транзакции |
| `POOL_MANAGER`, `POSITION_MANAGER`, `PERMIT2` | да | Uniswap V4 в целевой сети |
| `USDG_ADDRESS` | да | pair-токен всех пулов, должен уже существовать |
| `VAULT_CONVERSION_THRESHOLD` | да | порог конверсии эпохи в единицах USDG (например `5000000` для 5 USDG с 6 знаками). 0 выключает автоматическую конверсию |
| `UNISWAP_V3_FACTORY` | да | фабрика Uniswap V3 с пулами USDG/актив, из неё адаптер берёт пулы |
| `GEMOON_OWNER` | нет | итоговый владелец всех контрактов, по умолчанию деплоер |
| `GEMOON_PROXY_ADMIN_OWNER` | нет | владелец четырёх ProxyAdmin, то есть кто может апгрейдить, по умолчанию `GEMOON_OWNER` |
| `HOOK_TOTAL_FEE_BIPS`, `HOOK_PROTOCOL_SHARE_BIPS` | нет | резервная комиссия хука в bips сделки (по умолчанию 125) и доля протокола в bips комиссии (по умолчанию 3333 = треть) |
| `REFERRALS_REF_SHARE_BIPS` | нет | доля реферера в bips протокольной доли, по умолчанию 1000 |
| `ADAPTER_TWAP_WINDOW` | нет | окно TWAP адаптера в секундах, по умолчанию 600 |
| `ADAPTER_MAX_SLIPPAGE_BPS` | нет | допуск от TWAP для каждого маршрута, по умолчанию 100 (1%) |
| `DEPLOY_ASSETS_FILE` | нет | список наградных активов, по умолчанию `tools/scripts/robinhood-assets.csv` (формат: заголовок, затем `Ticker,Contract address,Uniswap V3 / USDG pool`) |
| `VAULT_ALLOWED_ASSETS` | нет | дополнительные активы через запятую, разрешаются без маршрута (например сам USDG). Актив не-USDG без маршрута отчёт помечает WARNING |
| `DEPLOY_REPORT` | нет | файл отчёта; `deploy.sh` задаёт его сам |

Протокольная доля комиссии всегда идёт в контракт рефералов, отдельный `PROTOCOL_FEE_RECIPIENT`
при полном деплое не нужен: протокольную часть владелец рефералов выводит через
`withdrawProtocolFees(to)`. `VAULT_SWAP_ADAPTER` полный деплой не читает, адаптер он создаёт сам.

**Сеть.** Проверить до старта:

- По адресу `0x4e59b44847b379578588920cA78FbF26c0B4956C` есть код. Это детерминированный
  CREATE2-деплоер, через него скрипт ставит имплементацию и прокси хука. Без него скрипт
  откажется работать. Проверка: `cast code 0x4e59b44847b379578588920cA78FbF26c0B4956C --rpc-url $RPC`.
- Лимит размера контракта (EIP-170, 24 576 байт) все контракты проходят: самый большой,
  GemoonController, ~12 КБ, Vault ~14 КБ (`forge build --sizes`).
- На деплоере есть нативный токен на газ. Весь прогон с 64 активами стоит порядка 40 млн газа
  (оценка симуляции на девнете), около половины уходит на allowlist и маршруты.
- Адреса Uniswap V4 верные для этой сети. Скрипт их не проверяет, ошибку покажет только первый
  `deployToken`.

**Прогон без broadcast.** Сначала симуляция, она ходит в RPC за состоянием, но ничего не
отправляет:

```sh
forge script --via-ir script/GemoonDeploy.sol:DeployGemoon --rpc-url $RPC --private-key $PRIVATE_KEY -vvvv
```

Удобнее `./deploy.sh --simulate`: та же симуляция плюс отчёт в `deploy-logs/`, по которому видно,
какие активы получат маршрут, а какие будут пропущены и почему. Если симуляция прошла и в отчёте
нет неожиданных SKIPPED/WARNING, запускать с broadcast.

## 2. Полный деплой

Рекомендуемый способ — `deploy.sh` в корне репозитория:

```sh
ENVIRONMENT=dev ./deploy.sh --simulate   # прогон без отправки транзакций, отчёт пишется
ENVIRONMENT=dev ./deploy.sh              # полный деплой
ENVIRONMENT=dev ./deploy.sh --no-lens    # то же без GemoonLens
ENVIRONMENT=prod ./deploy.sh --simulate  # то же для mainnet, из env/prod.mk
```

Что делает скрипт:

1. Проверяет `ENVIRONMENT` и `env/$ENVIRONMENT.mk`, файл активов и что у `POOL_MANAGER`, `POSITION_MANAGER`, `PERMIT2`,
   `USDG_ADDRESS`, `UNISWAP_V3_FACTORY` и CREATE2-деплоера есть код в сети.
2. `make deploy-gemoon` (симуляция — `make simulate-gemoon`): весь деплой одним forge-скриптом,
   таблица шагов ниже.
3. Читает из лога адреса и пишет их в `env/$ENVIRONMENT.mk`: `VAULT_/HOOK_/CONTROLLER_/REFERRALS_PROXY_ADDRESS`,
   `*_PROXY_ADMIN_ADDRESS`, `SWAP_ADAPTER`, `VAULT_SWAP_ADAPTER`. Перед правкой делает копию
   `env/$ENVIRONMENT.mk.bak.<время>`.
4. `make verify-wiring`: read-only проверка связки по сети, включая рефералы и адаптер.
5. `make deploy-lens`, адрес в `LENS_ADDRESS`.
6. Дописывает в отчёт Lens и итог (broadcast, проверка связки, что записано в `env/$ENVIRONMENT.mk`) и печатает
   отчёт.

**Отчёт** `deploy-logs/deploy-<время>-report.md`: что задеплоено, куда и зачем. В нём:

- все контракты: прокси, имплементация, ProxyAdmin с владельцем, назначение каждого; внешние
  контракты;
- связка: кто на кого указывает и зачем;
- конфигурация: комиссии, доли, порог, окно TWAP, допуск;
- владельцы и pending-владельцы;
- таблица активов: пул, fee-tier, результат (`allowed + routed` или `SKIPPED` с причиной);
- что осталось сделать руками.

Полный вывод forge лежит рядом в `deploy-<время>.log`. Оба файла в `.gitignore`. Табличную часть
отчёта строит forge-скрипт до отправки транзакций. Если broadcast упал, `deploy.sh` дописывает в
отчёт раздел «Result» с пометкой FAILED.

Без скрипта то же самое делается вручную: `make deploy-gemoon ENVIRONMENT=dev DEPLOY_REPORT=deploy-logs/report.md`,
дальше адреса из лога переносятся в `env/dev.mk` руками.

Скрипт `DeployGemoon` делает всё в одном прогоне, транзакции уходят по очереди (`--slow`).
Порядок и что происходит на каждом шаге:

| # | Транзакция | Кто | Комментарий |
|---|---|---|---|
| 1 | Библиотеки `Deployer`, `Ticks` | деплоер | внешние библиотеки, forge линкует и ставит их сам |
| 2 | `Vault` имплементация и прокси, `initialize(deployer, USDG)` | деплоер | владелец пока деплоер, чтобы настроить в этом же прогоне. Прокси сам создаёт ProxyAdmin с владельцем `GEMOON_PROXY_ADMIN_OWNER` |
| 3 | `Vault.setConversionThreshold`, `setAssetAllowed` на активы из `VAULT_ALLOWED_ASSETS` | деплоер | порог пропускается, если равен 0 |
| 4 | `GemoonController` имплементация и прокси, `initialize(POOL_MANAGER, USDG, deployer)` | деплоер | владелец пока деплоер |
| 5 | `GmoonReferrals` имплементация и прокси, `initialize(deployer, USDG, controller, 0, refShare)` | деплоер | до хука: хук получает рефералы как получателя протокольной доли в `initialize` |
| 6 | `HookManager` имплементация и прокси через CREATE2, `initialize(GEMOON_OWNER, referrals, vault, controller, fee, protocolShare)` | деплоер | соль майнится под биты разрешений. Хуку больше ничего не нужно, поэтому владелец сразу итоговый |
| 7 | `Controller.setReferrals`, `Referrals.setHook`; `Vault.setHook`, `setController`; `Controller.setHook`, `setVault`, `setPositionManager` | деплоер | рефералы подключаются первыми: `deployToken` открывается с `setPositionManager`, мем до `setReferrals` остался бы без реферера. `setHook`/`setVault` контроллера проверяют, что pair-токен совпадает |
| 8 | `UniswapV3SwapAdapter(deployer, UNISWAP_V3_FACTORY, vault, USDG, window)`, `Vault.setSwapAdapter` | деплоер | адаптер не прокси, привязан к этому волту |
| 9 | на каждую строку файла активов: `Vault.setAssetAllowed`, `Adapter.setRoute(asset, fee, slippage)` | деплоер | только если актив имеет код, пул — фабричный пул USDG/актив своего fee-tier и отдаёт TWAP за окно. Иначе строка пропускается, причина в отчёте. Уже разрешённое и с тем же маршрутом не отправляется |
| 10 | `transferOwnership(GEMOON_OWNER)` у Vault, Controller, Referrals, Adapter | деплоер | только если владелец отличается от деплоера. Контроллер переходит сразу, остальные остаются pending до `acceptOwnership` |
| 11 | `checkWiring`, `checkReferralsWiring`, `checkAdapterWiring`, `checkAssets` | view | скрипт падает, если что-то не сошлось |

Активы без маршрута в allowlist не попадают: мемы с таким активом не смогли бы конвертировать
комиссии. Пропущенные строки после исправления пула добиваются `make set-asset-allowed` и
`make set-route` с тем же файлом (раздел 3a).

**Если скрипт упал посередине.** Ничего страшного: контроллер не деплоит токены, пока не заданы
хук, волт и PositionManager, хук отвергает пулы незарегистрированных мемов, волт принимает
комиссии только от своего хука. Варианты:

- Повторить `make deploy-gemoon`. Будет новый полный набор контрактов, старые останутся
  мусором. Проще всего, если ещё ничего никому не отдавали.
- Дошить руками через `cast send` оставшиеся шаги из таблицы, все они обычные вызовы владельца.
  Адреса уже задеплоенных прокси брать из `broadcast/GemoonDeploy.sol/<chainId>/run-latest.json`.

## 3. После деплоя

1. Прочитать отчёт `deploy-logs/deploy-<время>-report.md`: раздел «Left to do» и строки
   `SKIPPED` / `WARNING` в таблице активов. `deploy.sh` уже перенёс адреса в `env/$ENVIRONMENT.mk`.
2. Если `GEMOON_OWNER` не деплоер, он принимает владение: `acceptOwnership()` на Vault,
   GmoonReferrals и UniswapV3SwapAdapter. До этого ими владеет деплоер. Хук и контроллер уже
   принадлежат `GEMOON_OWNER`.
3. `make verify-wiring` (deploy.sh уже запускал): read-only, печатает владельцев, pending
   владельцев, ProxyAdmin, адаптер, размер allowlist, падает при расхождении.
4. Пропущенные активы, если есть: исправить пул (см. 3a), затем `make set-asset-allowed` и
   `make set-route` от владельца.
5. Контракты верифицируются в эксплорере, см. п. 6.
6. Верифицировать контракты в эксплорере. Аргументы конструкторов:

```sh
# имплементации волта и контроллера: без аргументов
forge verify-contract $VAULT_IMPL src/contracts/vault/Vault.sol:Vault --chain-id $CHAIN_ID --verifier <verifier> --verifier-url <url>

# имплементация хука
forge verify-contract $HOOK_IMPL src/contracts/hooks/HookManager.sol:HookManager --chain-id $CHAIN_ID \
  --constructor-args $(cast abi-encode "constructor(address,address)" $POOL_MANAGER $USDG_ADDRESS) ...

# любой из трёх прокси: (имплементация, владелец ProxyAdmin, calldata initialize)
forge verify-contract $PROXY lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy \
  --chain-id $CHAIN_ID --constructor-args $(cast abi-encode "constructor(address,address,bytes)" $IMPL $GEMOON_PROXY_ADMIN_OWNER $INIT_DATA) ...
```

Calldata `initialize` для прокси можно взять из `broadcast/.../run-latest.json`, поле
`arguments` у транзакции создания.

7. Первый `deployToken` сделать самим и проверить, что событие `PositionCreated` пришло с
   ненулевой ликвидностью. Помнить, что комиссия первого свопа в свежем деплое остаётся
   начисленной в хуке до следующего свопа, это нормально.

## 3a. Swap adapter

Кипера нет: эпоха закрывается автоматически внутри `notifyFees`, когда накопленный USDG достигает
`VAULT_CONVERSION_THRESHOLD`, а защиту цены обеспечивает адаптер по TWAP пула. Поэтому адаптер
обязателен для рабочей конверсии. Адаптер работает с пулами Uniswap V3, потому что там лежит
ликвидность наградных активов и там есть встроенный TWAP-оракул; пул берётся из фабрики по
(USDG, актив, fee-tier), а не из произвольного адреса. Почему именно так, описано в `README.md`,
раздел «Swap adapter: почему Uniswap V3». Если ликвидность в целевой сети в другом DEX, нужен
другой адаптер под тот же `ISwapAdapter`, волт при этом не меняется.

```sh
make deploy-swap-adapter
```

Полный деплой ставит адаптер и маршруты сам. Ниже описан ручной путь: замена адаптера у
существующего волта или добивка пропущенных активов.

Скрипт `DeployUniswapV3SwapAdapter` читает `UNISWAP_V3_FACTORY`, `VAULT_PROXY_ADDRESS`,
`USDG_ADDRESS`, `ADAPTER_TWAP_WINDOW`, проверяет, что USDG совпадает с `Vault.usdg()`, и ставит
адаптер с владельцем `GEMOON_OWNER`. Дальше руками:

1. Для каждого наградного актива должен существовать пул USDG/актив в этой фабрике, и у пула
   должна быть история наблюдений не короче окна TWAP:
   `cast send $POOL "increaseObservationCardinalityNext(uint16)" 120 --rpc-url $RPC ...`
   (при блоке в 2 секунды 300 наблюдений покрывают 10 минут, с запасом ставить больше).
   Свежий пул отдаёт `OLD` на `observe`, пока история не накопится.
2. Владелец адаптера задаёт маршрут: `setRoute(asset, fee, maxSlippageBps)`, где `fee` это
   fee-tier пула, `maxSlippageBps` допуск от TWAP, рекомендуемо `100` (1%), потолок в коде 500.
   `setRoute` сам проверяет, что пул найден и может отдать TWAP.
3. Владелец волта зовёт `Vault.setSwapAdapter(adapter)`.
4. Проверка: `adapter.quote(asset, 1e6)` и `adapter.minAmountOut(asset, 1e6)` отдают ненулевые
   значения, `Vault.pendingUSDG(meme)` после первого свопа выше порога обнуляется, в логах есть
   `FeesConverted`.

Если конверсии падают, волт эмитит `ConversionFailed(meme, reason)` и ждёт минуту до следующей
попытки. Причину видно в `reason`: `OLD` это нехватка истории у пула, `InsufficientOutput` это
отклонение спота от TWAP больше допуска, `RouteNotSet` это забытый `setRoute`. Любой может
дёрнуть `Vault.convertFees(meme)` вручную, когда причина устранена.

## 4. Апгрейды

Общее для всех трёх:

- Транзакцию апгрейда отправляет владелец ProxyAdmin, то есть `GEMOON_PROXY_ADMIN_OWNER`.
  Скрипты проверяют это и падают, если broadcaster не он. Если владелец мультисиг, скриптом
  задеплоить только имплементацию, а `ProxyAdmin.upgradeAndCall(proxy, impl, data)` отправить
  из мультисига.
- Перед апгрейдом сравнить storage layout: `forge inspect Vault storageLayout` против
  задеплоенной версии. Поля только добавляются в конец, ничего не переставляется и не меняет тип.
- Сначала симуляция без broadcast, потом `make upgrade-*`.

| Цель | Что делает | Особенности |
|---|---|---|
| `make upgrade-vault-proxy` | новая имплементация, `upgradeAndCall` | если `VAULT_VERSION` вырос, атомарно зовётся `reinitialize()`, иначе апгрейд без вызова. После проверяет владельца, USDG и адрес имплементации |
| `make upgrade-hook-proxy` | новая имплементация через CREATE2, `upgradeAndCall` | адрес имплементации снова майнится под биты разрешений. При росте `HOOK_MANAGER_VERSION` зовётся `reinitialize` с текущими владельцем, получателем, волтом, контроллером и комиссиями. После проверяет, что адрес прокси всё ещё подходит под разрешения новой имплементации |
| `make upgrade-controller-proxy` | новая имплементация, `upgradeAndCall` с `reinitialize` | `reinitialize` защищён `reinitializer(GEMOON_VERSION)`, а версия равна 1, которую занял `initialize`. Пока версия не поднята, апгрейд с вызовом упадёт. Для апгрейда без вызова поднять версию или отправить `upgradeAndCall` с пустыми данными |

**Апгрейд существующего контроллера на 2.0.** После смены имплементации владелец контроллера
обязан вызвать `setHook`, `setVault` и `setPositionManager(positionManager, permit2)`, иначе
`deployToken` падает на `HookNotSet` / `VaultNotSet` / `PositionManagerNotSet`. Старый слот
`_deployStrategies` в storage остаётся, его трогать нельзя.

## 5. Девнет

Девнет `https://rpc-testnet.gmoon.xyz` это anvil, запущенный как форк Robinhood Chain
(`--fork-url`, настоящий chain id 4663), локальный chain id 1488. Адреса Uniswap V4 и USDG в нём
настоящие адреса Robinhood Chain:

| Переменная | Адрес |
|---|---|
| `POOL_MANAGER` | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| `POSITION_MANAGER` | `0x58daec3116aae6d93017baaea7749052e8a04fa7` |
| `PERMIT2` | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| `USDG_ADDRESS` | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` (Global Dollar, 6 знаков) |

 Профинансированный аккаунт и ключ лежат в `env/dev.mk` как
`OPERATOR_ADDRESS` и `OPERATOR_PRIVATE_KEY`, форк-тесты и деплой берут их оттуда. Дефолтный
anvil-аккаунт `0xf39F…2266` на девнете пуст, на него полагаться нельзя.

Отличия от боевого прогона:

- USDG настоящий, mint у него нет. Чтобы получить USDG на девнете для пробных сделок, его
  выдают через `anvil_setStorageAt` или покупают на форке у существующих пулов.
- Форк-тесты `make devnet-tests` в сеть ничего не отправляют, баланс аккаунта от них не
  меняется. Реальный деплой только через `make deploy-gemoon`.

**Как устроено хранение состояния и чем это ломается.** Anvil держит локально только те аккаунты,
которые кто-то трогал после старта форка. За остальными он ходит в upstream Sepolia-ноду на блоке
форка. Отсюда два типичных отказа:

- `state at block #N is pruned` на деплое. Upstream это не archive-нода, и блок форка выпал из её
  окна. Деплой-скрипт проверяет nonce и код по будущим адресам `CREATE`/`CREATE2`, anvil их не
  знает, идёт в upstream и получает отказ. Форк-тесты при этом могут проходить, потому что все их
  адреса уже закешированы. Лечится перезапуском anvil с archive-RPC в `--fork-url` при том же
  `--fork-block-number`, либо новым форком от свежего блока ценой потери локального состояния.
- `operation timed out` в forge при живом порте. Так ведёт себя anvil с `--block-time`: на цепочке
  в миллионы блоков майнинг пустого блока с обрезкой истории держит бэкенд под lock-ом, и RPC не
  успевает ответить за 45 секунд таймаута forge. Интервальный майнинг на этом инстансе не
  включать; для хода времени есть `evm_increaseTime`, `evm_mine` и `anvil_setBlockTimestampInterval`.

Рекомендуемый запуск: `--fork-url <archive RPC Robinhood Chain>`, `--state <файл>`, без
`--block-time`. `--fork-block-number` ставить только вместе с archive-RPC: с обычным RPC
состояние этого блока со временем удаляется upstream-нодой, и чтения падают с
`historical state ... is not available`. `--state` сохраняет и поднимает состояние между рестартами,
иначе после `--load-state` нода знает только последний блок и запросы с `--block` отвечают
`BlockOutOfRange`. Конфигурацию работающей ноды показывает
`cast rpc anvil_nodeInfo --rpc-url $DEVNET_RPC`.

## 6. Чеклист

- [ ] `env/<ENVIRONMENT>.mk` заполнен, для prod заданы `GEMOON_OWNER` и `GEMOON_PROXY_ADMIN_OWNER`, `USDG_ADDRESS` указывает на существующий токен
- [ ] CREATE2-деплоер есть в сети
- [ ] симуляция `DeployGemoon` без broadcast прошла
- [ ] `./deploy.sh --simulate`: в отчёте нет неожиданных SKIPPED / WARNING
- [ ] `./deploy.sh`, в отчёте «Result»: broadcast OK, wiring OK
- [ ] `GEMOON_OWNER` вызвал `acceptOwnership` на Vault, GmoonReferrals, UniswapV3SwapAdapter
- [ ] пропущенные активы добиты (`set-asset-allowed`, `set-route`) или осознанно оставлены
- [ ] контракты верифицированы
- [ ] пробный `deployToken` дал `PositionCreated` с ликвидностью
