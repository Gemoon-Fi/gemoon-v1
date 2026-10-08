# Развёртывание Gemoon

Инструкция для того, кто запускает деплой и апгрейды. Что делают контракты, описано в `README.md`.

## 1. Перед запуском

**Окружение.** Foundry установлен, `forge build` проходит. Переменные в `.env` в корне репозитория.
Пустое значение считается незаданным.

| Переменная | Обязательна | Что это |
|---|---|---|
| `RPC` | да | RPC целевой сети |
| `PRIVATE_KEY` | да | ключ деплоера, с него уходят все транзакции |
| `POOL_MANAGER`, `POSITION_MANAGER`, `PERMIT2` | да | Uniswap V4 в целевой сети |
| `USDG_ADDRESS` | да | pair-токен всех пулов, должен уже существовать |
| `PROTOCOL_FEE_RECIPIENT` | да | получатель протокольной доли комиссии |
| `VAULT_CONVERSION_THRESHOLD` | да | порог конверсии эпохи в единицах USDG (например `5000000` для 5 USDG с 6 знаками). 0 выключает автоматическую конверсию |
| `GEMOON_OWNER` | нет | итоговый владелец трёх контрактов, по умолчанию деплоер |
| `GEMOON_PROXY_ADMIN_OWNER` | нет | владелец трёх ProxyAdmin, то есть кто может апгрейдить, по умолчанию `GEMOON_OWNER` |
| `HOOK_TOTAL_FEE_BIPS`, `HOOK_PROTOCOL_FEE_BIPS` | нет | комиссия хука, по умолчанию 125 и 25 |
| `VAULT_SWAP_ADAPTER` | нет | адаптер USDG в наградные активы, можно задать позже |
| `VAULT_ALLOWED_ASSETS` | нет | allowlist наградных активов через запятую, можно задать позже |
| `UNISWAP_V3_FACTORY` | для адаптера | фабрика Uniswap V3, в которой есть пулы USDG/актив |
| `ADAPTER_TWAP_WINDOW` | нет | окно TWAP адаптера в секундах, по умолчанию 600 |

**Сеть.** Проверить до старта:

- По адресу `0x4e59b44847b379578588920cA78FbF26c0B4956C` есть код. Это детерминированный
  CREATE2-деплоер, через него скрипт ставит имплементацию и прокси хука. Без него скрипт
  откажется работать. Проверка: `cast code 0x4e59b44847b379578588920cA78FbF26c0B4956C --rpc-url $RPC`.
- Лимит размера контракта. Vault сейчас 27 188 байт при стандартном лимите 24 576. Monad
  пропускает, Ethereum-подобные сети и anvil по умолчанию нет. Для anvil нужен флаг
  `--disable-code-size-limit`.
- На деплоере есть нативный токен на газ. Весь прогон стоит порядка 20 млн газа, из них
  большая часть на имплементации.
- Адреса Uniswap V4 верные для этой сети. Скрипт их не проверяет, ошибку покажет только первый
  `deployToken`.

**Прогон без broadcast.** Сначала симуляция, она ходит в RPC за состоянием, но ничего не
отправляет:

```sh
forge script --via-ir script/GemoonDeploy.sol:DeployGemoon --rpc-url $RPC --private-key $PRIVATE_KEY -vvvv
```

В логе должны быть адреса всех трёх прокси и строка про владельцев. Если симуляция прошла,
запускать с broadcast.

## 2. Полный деплой

```sh
make deploy-gemoon
```

Скрипт `DeployGemoon` делает всё в одном прогоне, транзакции уходят по очереди (`--slow`).
Порядок и что происходит на каждом шаге:

| # | Транзакция | Кто | Комментарий |
|---|---|---|---|
| 1 | Библиотеки `Deployer`, `Ticks` | деплоер | внешние библиотеки, forge линкует и ставит их сам |
| 2 | `Vault` имплементация | деплоер | |
| 3 | `Vault` прокси, `initialize(deployer, USDG)` | деплоер | владелец пока деплоер, чтобы настроить в этом же прогоне. Прокси сам создаёт ProxyAdmin с владельцем `GEMOON_PROXY_ADMIN_OWNER` |
| 4 | `Vault.setConversionThreshold`, `setSwapAdapter`, `setAssetAllowed` на каждый актив | деплоер | порог пропускается, если равен 0, адаптер и allowlist, если не заданы |
| 5 | `GemoonController` имплементация | деплоер | |
| 6 | `GemoonController` прокси, `initialize(POOL_MANAGER, USDG, deployer)` | деплоер | владелец пока деплоер |
| 7 | `HookManager` имплементация через CREATE2 | деплоер | соль подбирается в скрипте так, чтобы адрес нёс биты разрешений хука |
| 8 | `HookManager` прокси через CREATE2, `initialize(GEMOON_OWNER, PROTOCOL_FEE_RECIPIENT, vault, controller, fee, protocolFee)` | деплоер | адрес прокси тоже майнится. Контроллер становится единственным, кто может звать `onlyController`-функции хука. Хуку больше ничего не нужно, поэтому владелец сразу итоговый |
| 9 | `Vault.setHook`, `Vault.setController` | деплоер | |
| 10 | `Controller.setHook`, `setVault`, `setPositionManager` | деплоер | `setHook` проверяет, что pair-токен хука равен USDG контроллера, `setVault` проверяет USDG волта |
| 11 | `Vault.transferOwnership(GEMOON_OWNER)`, `Controller.transferOwnership(GEMOON_OWNER)` | деплоер | только если владелец отличается от деплоера. У контроллера владение переходит сразу, у волта остаётся pending |
| 12 | `checkWiring` | view | скрипт падает, если что-то не сошлось |

Порядок именно такой, потому что хук требует адреса волта и контроллера в `initialize`, а
контроллер и волт принимают хук сеттерами. Никаких временных нулевых адресов и предсказания адресов не нужно.

**Если скрипт упал посередине.** Ничего страшного: контроллер не деплоит токены, пока не заданы
хук, волт и PositionManager, хук отвергает пулы незарегистрированных мемов, волт принимает
комиссии только от своего хука. Варианты:

- Повторить `make deploy-gemoon`. Будет новый полный набор контрактов, старые останутся
  мусором. Проще всего, если ещё ничего никому не отдавали.
- Дошить руками через `cast send` оставшиеся шаги из таблицы, все они обычные вызовы владельца.
  Адреса уже задеплоенных прокси брать из `broadcast/GemoonDeploy.sol/<chainId>/run-latest.json`.

## 3. После деплоя

1. Перенести адреса из лога в `.env`: `VAULT_PROXY_ADDRESS`, `VAULT_PROXY_ADMIN_ADDRESS`,
   `HOOK_PROXY_ADDRESS`, `HOOK_PROXY_ADMIN_ADDRESS`, `CONTROLLER_PROXY_ADDRESS`,
   `CONTROLLER_PROXY_ADMIN_ADDRESS`. Они нужны апгрейдам и проверке.
2. `GEMOON_OWNER` принимает волт: `Vault.acceptOwnership()`. До этого волтом владеет деплоер.
   Хук и контроллер уже принадлежат `GEMOON_OWNER`.
3. Проверить связку: `make verify-wiring`. Это read-only скрипт, печатает владельцев, pending
   владельцев, ProxyAdmin и их владельцев, падает при расхождении.
4. Если allowlist не задавали в `.env`, владелец волта задаёт его сейчас:
   `setAssetAllowed(asset, true)` на каждый актив. Без allowlist `deployToken` будет падать на
   `AssetNotAllowed`.
5. Поднять swap adapter, см. раздел «Swap adapter» ниже. Без адаптера конверсия эпох будет
   падать, начисления останутся в USDG до его появления.
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

Девнет это anvil, запущенный как форк Sepolia (`--fork-url`), chain id 1337. Адреса Uniswap V4
в нём настоящие Sepolia-адреса. Профинансированный аккаунт и ключ лежат в `.env` как
`OPERATOR_ADDRESS` и `OPERATOR_PRIVATE_KEY`, форк-тесты и деплой берут их оттуда. Дефолтный
anvil-аккаунт `0xf39F…2266` на девнете пуст, на него полагаться нельзя.

Отличия от боевого прогона:

- Пары USDG на девнете нет. Задеплоить любой ERC20 и записать его в `USDG_ADDRESS`, иначе
  `DeployGemoon` упадёт на чтении переменной.
- Vault больше лимита EIP-170, anvil должен быть запущен с `--disable-code-size-limit`.
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

Рекомендуемый запуск: `--fork-url <archive sepolia>`, `--disable-code-size-limit`,
`--state <файл>`, без `--block-time`. `--state` сохраняет и поднимает состояние между рестартами,
иначе после `--load-state` нода знает только последний блок и запросы с `--block` отвечают
`BlockOutOfRange`. Конфигурацию работающей ноды показывает
`cast rpc anvil_nodeInfo --rpc-url $DEVNET_RPC`.

## 6. Чеклист

- [ ] `.env` заполнен, `USDG_ADDRESS` указывает на существующий токен
- [ ] CREATE2-деплоер есть в сети
- [ ] сеть пропускает контракт в 27 КБ
- [ ] симуляция `DeployGemoon` без broadcast прошла
- [ ] `make deploy-gemoon`
- [ ] адреса из лога перенесены в `.env`
- [ ] `GEMOON_OWNER` вызвал `Vault.acceptOwnership`
- [ ] `make verify-wiring` зелёный
- [ ] allowlist активов задан, `VAULT_CONVERSION_THRESHOLD` ненулевой
- [ ] swap adapter задеплоен, маршруты на все активы заданы, у пулов хватает observation cardinality
- [ ] `Vault.setSwapAdapter` вызван
- [ ] контракты верифицированы
- [ ] пробный `deployToken` дал `PositionCreated` с ликвидностью
