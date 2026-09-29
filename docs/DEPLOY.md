# Развёртывание Gemoon

Инструкция для того, кто запускает деплой и апгрейды. Что делают контракты, описано в `README.md`.

## 1. Перед запуском

**Окружение.** Foundry установлен, `forge build` проходит. Переменные в `.env` в корне репозитория,
шаблон в `.env.example`. Пустое значение считается незаданным.

| Переменная | Обязательна | Что это |
|---|---|---|
| `RPC` | да | RPC целевой сети |
| `PRIVATE_KEY` | да | ключ деплоера, с него уходят все транзакции |
| `POOL_MANAGER`, `POSITION_MANAGER`, `PERMIT2` | да | Uniswap V4 в целевой сети |
| `USDG_ADDRESS` | да | pair-токен всех пулов, должен уже существовать |
| `PROTOCOL_FEE_RECIPIENT` | да | получатель протокольной доли комиссии |
| `VAULT_KEEPER` | да | адрес, который будет звать `convertFees` |
| `GEMOON_OWNER` | нет | итоговый владелец трёх контрактов, по умолчанию деплоер |
| `GEMOON_PROXY_ADMIN_OWNER` | нет | владелец трёх ProxyAdmin, то есть кто может апгрейдить, по умолчанию `GEMOON_OWNER` |
| `HOOK_TOTAL_FEE_BIPS`, `HOOK_PROTOCOL_FEE_BIPS` | нет | комиссия хука, по умолчанию 125 и 25 |
| `VAULT_SWAP_ADAPTER` | нет | адаптер USDG в наградные активы, можно задать позже |
| `VAULT_ALLOWED_ASSETS` | нет | allowlist наградных активов через запятую, можно задать позже |

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
| 4 | `Vault.setKeeper`, `setSwapAdapter`, `setAssetAllowed` на каждый актив | деплоер | адаптер и allowlist пропускаются, если не заданы |
| 5 | `HookManager` имплементация через CREATE2 | деплоер | соль подбирается в скрипте так, чтобы адрес нёс биты разрешений хука |
| 6 | `HookManager` прокси через CREATE2, `initialize(GEMOON_OWNER, PROTOCOL_FEE_RECIPIENT, vault, fee, protocolFee)` | деплоер | адрес прокси тоже майнится. Хуку больше ничего не нужно, поэтому владелец сразу итоговый |
| 7 | `GemoonController` имплементация | деплоер | |
| 8 | `GemoonController` прокси, `initialize(POOL_MANAGER, USDG, deployer)` | деплоер | владелец пока деплоер |
| 9 | `Vault.setHook`, `Vault.setController` | деплоер | |
| 10 | `Controller.setHook`, `setVault`, `setPositionManager` | деплоер | `setHook` проверяет, что pair-токен хука равен USDG контроллера, `setVault` проверяет USDG волта |
| 11 | `Vault.transferOwnership(GEMOON_OWNER)`, `Controller.transferOwnership(GEMOON_OWNER)` | деплоер | только если владелец отличается от деплоера. У контроллера владение переходит сразу, у волта остаётся pending |
| 12 | `checkWiring` | view | скрипт падает, если что-то не сошлось |

Порядок именно такой, потому что хук требует адрес волта в `initialize`, а контроллер и волт
принимают хук сеттерами. Никаких временных нулевых адресов и предсказания адресов не нужно.

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
4. Если allowlist и адаптер не задавали в `.env`, владелец волта задаёт их сейчас:
   `setAssetAllowed(asset, true)` на каждый актив и `setSwapAdapter(adapter)`. Без allowlist
   `deployToken` будет падать на `AssetNotAllowed`, без адаптера keeper не сможет конвертировать.
5. Верифицировать контракты в эксплорере. Аргументы конструкторов:

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

6. Первый `deployToken` сделать самим и проверить, что событие `PositionCreated` пришло с
   ненулевой ликвидностью. Помнить, что комиссия первого свопа в свежем деплое остаётся
   начисленной в хуке до следующего свопа, это нормально.

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
| `make upgrade-hook-proxy` | новая имплементация через CREATE2, `upgradeAndCall` | адрес имплементации снова майнится под биты разрешений. При росте `HOOK_MANAGER_VERSION` зовётся `reinitialize` с текущими владельцем, получателем, волтом и комиссиями. После проверяет, что адрес прокси всё ещё подходит под разрешения новой имплементации |
| `make upgrade-controller-proxy` | новая имплементация, `upgradeAndCall` с `reinitialize` | `reinitialize` защищён `reinitializer(GEMOON_VERSION)`, а версия равна 1, которую занял `initialize`. Пока версия не поднята, апгрейд с вызовом упадёт. Для апгрейда без вызова поднять версию или отправить `upgradeAndCall` с пустыми данными |

**Апгрейд существующего контроллера на 2.0.** После смены имплементации владелец контроллера
обязан вызвать `setHook`, `setVault` и `setPositionManager(positionManager, permit2)`, иначе
`deployToken` падает на `HookNotSet` / `VaultNotSet` / `PositionManagerNotSet`. Старый слот
`_deployStrategies` в storage остаётся, его трогать нельзя.

## 5. Девнет

Sepolia-форк на anvil, chain id 1337, аккаунт `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`.
Адреса Uniswap V4 и ключ уже в `.env` в разделе девнета. Отличия от боевого прогона:

- Пары USDG на девнете нет. Задеплоить любой ERC20 и записать его в `USDG_ADDRESS`, иначе
  `DeployGemoon` упадёт на чтении переменной.
- Vault больше лимита EIP-170, anvil должен быть запущен с `--disable-code-size-limit`.
- Форк-тесты `make devnet-tests` в сеть ничего не отправляют, баланс аккаунта от них не
  меняется. Реальный деплой только через `make deploy-gemoon`.

## 6. Чеклист

- [ ] `.env` заполнен, `USDG_ADDRESS` указывает на существующий токен
- [ ] CREATE2-деплоер есть в сети
- [ ] сеть пропускает контракт в 27 КБ
- [ ] симуляция `DeployGemoon` без broadcast прошла
- [ ] `make deploy-gemoon`
- [ ] адреса из лога перенесены в `.env`
- [ ] `GEMOON_OWNER` вызвал `Vault.acceptOwnership`
- [ ] `make verify-wiring` зелёный
- [ ] allowlist активов и swap adapter заданы
- [ ] контракты верифицированы
- [ ] пробный `deployToken` дал `PositionCreated` с ликвидностью
