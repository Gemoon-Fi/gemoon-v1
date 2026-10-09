# Данные для фронта: откуда брать и как считать

Справочник для индексатора и фронтенда. На каждую метрику Main Page и Staking Page указано, из
каких событий или view-функций она берётся и по какой формуле считается.

Соглашения:

- Pair-токен всех пулов это USDG, долларовый стейблкоин. Цена в USDG это цена в USD.
- Все суммы в сырых единицах контрактов. Decimals: USDG 6, мем 18, у наградных активов свои.
  Делить на `10^decimals` при выводе.
- Метрики со значком \* зависят от адреса пользователя и считаются на его кошелёк.
- `now − 24h` везде означает «по `block.timestamp` события».

## 1. Что индексировать

Три контракта протокола плюс PoolManager Uniswap V4 и ERC20 каждого мема.

| Контракт | События | View-функции |
|---|---|---|
| `GemoonController` | `TokenCreated`, `PoolCreated`, `PositionCreated`, `DevBuy` | |
| `HookManager` (`IHookManager.json`) | `MemeSwapped`, `FeeCharged`, `FeesDistributed`, `PayoutFailed` | `pendingFees` |
| `Vault` | `VaultRegistered`, `FeesNotified`, `FeesConverted`, `ConversionFailed`, `Staked`, `Unstaked`, `EmergencyUnstaked`, `RewardPaid`, `CreatorRewardPaid`, `CreatorTransferred` | `earned`, `pendingCreditOf`, `pendingUSDG`, `totalStaked`, `stakedOf`, `getAssets`, `creatorAccrued` |
| `UniswapV3SwapAdapter` | `Swapped` | `quote` |
| `PoolManager` (Uniswap V4, `IPoolManager.json`) | `Swap` | |
| ERC20 мема | `Transfer`, `UpdateImage`, `UpdateDescription` | `imageAddress`, `description`, `getSocialMedia`, `balanceOf` |

Сигнатуры:

```
GemoonController
  TokenCreated(address indexed token, address indexed creatorAdmin, uint256 indexed positionId,
               address creatorRewardRecipient, string name, string symbol)
  PoolCreated(PoolId indexed pool, address indexed token0, address indexed token1,
              uint256 initialPrice, int24 tick)            // initialPrice это sqrtPriceX96
  DevBuy(address indexed token, address indexed buyer,
         uint256 pairIn, uint256 memeOut)                   // первая покупка создателем в
                                                            // deployToken; pairIn с комиссией

HookManager
  MemeSwapped(address indexed meme, address indexed router, address indexed trader,
              bool isBuy, uint256 pairAmount, uint256 memeAmount, uint256 fee)
  FeeCharged(PoolId indexed poolId, address indexed sender, uint256 amount)
  FeesDistributed(address indexed meme, address indexed protocolRecipient,
                  address indexed vault, uint256 toProtocol, uint256 toVault)
  PayoutFailed(bytes reason)                                // автовыплата после свопа не прошла,
                                                            // комиссия осталась в pendingFees

Vault
  VaultRegistered(address indexed meme, address indexed creator, AssetConfig[] assets)
  FeesNotified(address indexed meme, uint256 toStakers, uint256 toCreator)
  FeesConverted(address indexed meme, uint64 indexed epoch, uint256 usdgIn,
                uint256[] toStakers, uint256[] toCreator)
  ConversionFailed(address indexed meme, bytes reason)
  Staked / Unstaked / EmergencyUnstaked(address indexed meme, address indexed account, uint256 amount)
  RewardPaid(address indexed meme, address indexed account, address indexed asset, uint256 amount)
  CreatorRewardPaid(address indexed meme, address indexed creator, address indexed asset, uint256 amount)
  CreatorTransferred(address indexed meme, address indexed from, address indexed to)

UniswapV3SwapAdapter
  Swapped(address indexed asset, uint256 amountIn, uint256 amountOut, uint256 twapOut, uint256 minAmountOut)

PoolManager
  Swap(PoolId indexed id, address indexed sender, int128 amount0, int128 amount1,
       uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)
```

## 2. Служебные величины

Эти величины нужны нескольким метрикам, считаются один раз.

| Величина | Откуда | Как считать |
|---|---|---|
| Список мемов | `TokenCreated` | Одна запись на событие: адрес, name, symbol, создатель, positionId, timestamp создания |
| Привязка пула к мему | `PoolCreated` | `pool` это `PoolId`, по нему фильтруются `Swap` PoolManager. `token0`/`token1` говорят, с какой стороны мем |
| Порядок активов волта | `VaultRegistered.assets[]` | Индекс в массиве фиксирован навсегда, им читаются `toStakers[i]` и `toCreator[i]` в `FeesConverted` |
| Сделка | `MemeSwapped` | Одна запись на своп: `meme`, `isBuy`, `pairAmount` (USDG-сторона по цене пула, без комиссии хука), `memeAmount`, `fee`, `trader`, `router`, timestamp. Покупатель заплатил `pairAmount + fee`, продавец получил `pairAmount − fee` |
| Трейдер сделки | `MemeSwapped.trader`, иначе `tx.from` | `trader` ненулевой, если фронт передал адрес в `hookData` свопа. Он самоназванный, годится для витрины. По умолчанию брать отправителя транзакции. Для кошельков ERC-4337 отправитель это bundler, пользователь в `UserOperationEvent.sender` той же транзакции |
| Price_now | последний `PoolManager.Swap` мема, до первого свопа `PoolCreated.initialPrice` | `p = (sqrtPriceX96 / 2^96)^2` это token1 за token0 в сырых единицах. Если мем это token1: `price = 1 / p × 10^12`. Если мем это token0: `price = p × 10^12`. Множитель `10^12` = `10^(18 − 6)` переводит в USDG за один мем |
| Price_24h | последний `Swap` с `timestamp ≤ now − 24h` | Та же формула. Если мему меньше 24 часов, берётся `PoolCreated.initialPrice` |
| Asset_Price_now | `UniswapV3SwapAdapter.quote(asset, 1e6)` либо внешний фид | `quote` возвращает, сколько сырых единиц актива покупается за 1 USDG по TWAP пула за вычетом комиссии пула. Цена актива в USD: `1e6 / quote × 10^(dec_asset − 6)`. Для «чистой» цены без комиссии пула разделить ещё на `(1 − fee)`. Тот же курс попадает в `Swapped.twapOut` на каждой конверсии |
| Staked_Amount | `Staked`, `Unstaked`, `EmergencyUnstaked` | По мему: Σ Staked − Σ Unstaked − Σ EmergencyUnstaked. Сверка: `Vault.totalStaked(meme)` |
| Эпохи и награды | `FeesConverted` | Награды в активах существуют только после этого события. До него комиссии лежат в USDG и видны в `FeesNotified` и `pendingUSDG(meme)` |

## 3. Main Page

| Метрика | Откуда | Как считать |
|---|---|---|
| Token CA | `TokenCreated.token` | |
| Token Image | `Token.imageAddress()` при индексации мема, затем `UpdateImage` по адресу токена | Событие без адреса в topic, фильтровать по `address` лога |
| Name, Ticker | `TokenCreated.name`, `.symbol` | |
| Vault Assets, Vault Assets Weight | `VaultRegistered.assets[]` | `token` и `weightBps`, сумма весов 10 000 |
| Vault Assets Logo | офчейн-словарь по адресу актива | Топ-4 по `weightBps`. В контрактах логотипов нет |
| Market Cap | Price_now, `Transfer` мема | `Price_now × (100_000_000_000e18 − balance(0x…dEaD))`. Эмиссия фиксированная, 100 млрд, константа `INITIAL_SUPPLY_X18`. Функции burn у токена нет, перевод на нулевой адрес ревертит, сожжённым считать только баланс `0xdEaD` |
| MC Change 24h | Price_now, Price_24h | `(Price_now / Price_24h − 1) × 100` |
| Volume 24h | `MemeSwapped` за 24h | `Σ pairAmount`. Это объём по цене пула. Если нужен объём «как заплатил пользователь», прибавлять `fee` |
| Age | `TokenCreated` | `now − timestamp` |
| Total Staked in token | Staked_Amount | |
| Total Staked in USD | Staked_Amount × Price_now | |
| Reward 24h Assets | `FeesConverted` за 24h | По каждому активу `i`: `Σ toStakers[i]`. Для карточки «всего заработал волт» можно прибавить `toCreator[i]`, для доходности стейкеров только `toStakers[i]` |
| Rewards 24h USD by Asset | Reward 24h Assets, Asset_Price_now | `Reward_24h_Assets[i] × Asset_Price_now[i]` |
| Rewards 24h USD | | Σ по активам |
| Yield Per Day | Rewards 24h USD, Staked_Amount, VWAP 24h | `Rewards_24h_USD / (Staked_Amount × VWAP_24h) × 100`. VWAP 24h = `Σ pairAmount / Σ memeAmount` по `MemeSwapped` за 24h. В числителе только стейкерская часть наград |
| Total Rewards Assets | `FeesConverted` за всё время | `Σ toStakers[i]` (+ `toCreator[i]` по желанию) |
| Total Rewards USD by Asset | | `Total_Rewards_Assets[i] × Asset_Price_now[i]` |
| Total Rewards USD | | Σ по активам |
| Pending USDG (рекомендуется показывать) | `pendingUSDG(meme)` или `Σ FeesNotified − Σ FeesConverted.usdgIn` | Комиссии уже пришли, активы ещё не куплены. Без этого «0 наград» у молодого мема выглядит ошибкой |

Про условие из черновика «если Volume 24h < 501, то Rewards 24h = 0»: оно не нужно. Эпоха
закрывается, когда накопленный USDG достигает порога (5 USDG, то есть 500 USDG объёма при
комиссии волту 1%). Если порог не набран, `FeesConverted` нет и суммы сами равны нулю. Опираться
надо на `FeesConverted`, а не на объём. То же для Total.

## 4. Staking Page

Всё, что есть на Main Page, считается так же. Дополнительно:

| Метрика | Откуда | Как считать |
|---|---|---|
| You Staked in token \* | `Staked`, `Unstaked`, `EmergencyUnstaked` по `account` | Σ Staked − Σ Unstaked − Σ EmergencyUnstaked для пары (meme, user). Сверка: `Vault.stakedOf(meme, user)` |
| You Staked in USD \* | You Staked × Price_now | |
| Доступно к стейку \* | `Token.balanceOf(user)` или `Transfer` мема | Баланс кошелька |
| Claimed by Asset \* | `RewardPaid` по (meme, user) | `Σ amount` по каждому `asset` |
| Unclaimed by Asset \* | `Vault.earned(meme, user)` | View, возвращает `assets[]` и `amounts[]` в порядке `VaultRegistered`. Из событий не восстанавливается, волт не эмитит персональные начисления. Вызывать через multicall по всем мемам, где у пользователя есть или был стейк |
| Earnings Assets \* | Claimed + Unclaimed | По каждому активу |
| Earnings USD by Asset \* | | `(Claimed[i] + Unclaimed[i]) × Asset_Price_now[i]` |
| Earnings USD \* | | Σ по активам |
| В ожидании конверсии \* (рекомендуется) | `Vault.pendingCreditOf(meme, user)` | USDG-кредит пользователя в открытой эпохе. Уже заработано, но ещё не превращено в активы. Показывать как USD «в пути» |

Для создателя мема то же самое через `CreatorRewardPaid` (claimed) и `Vault.creatorAccrued(meme)`
(unclaimed). Текущий создатель меняется событием `CreatorTransferred`.

## 5. Цена наградных активов на каждой конверсии

На каждом закрытии эпохи адаптер пишет `Swapped` по каждому активу волта:

- `amountIn / amountOut` это фактическая цена покупки, USDG за единицу актива;
- `amountIn / twapOut` это цена по TWAP пула за вычетом комиссии пула;
- привязка к мему через транзакцию, в ней же лежит `FeesConverted(meme, …)`.

Этого хватает для истории цен. Для текущей цены между конверсиями дёргать `quote` как view, это
бесплатно.

## 6. Ловушки

- `PoolCreated.initialPrice` это sqrtPriceX96, а не цена, несмотря на название.
- `FeesConverted` не несёт адресов активов, только массивы по индексу из `VaultRegistered`.
- `PoolManager.Swap.sender` это роутер, трейдера там нет. Трейдер только в `MemeSwapped.trader`
  или `tx.from`.
- `MemeSwapped.pairAmount` это сумма по цене пула. Комиссия хука в ней не учтена и лежит в `fee`.
- Dev buy это обычная сделка: хук эмитит `MemeSwapped` с `router` = контроллер и `trader` =
  покупатель, в той же транзакции, что `TokenCreated`. В объём он входит, дублировать его из
  `DevBuy` не нужно.
- Эпохи у каждого мема свои, `epoch` в `FeesConverted` растёт независимо по мемам.
- `Unclaimed` и `pendingCreditOf` только через view. Если фронту нужен список мемов для
  multicall, собирать его из `Staked` по адресу пользователя.
