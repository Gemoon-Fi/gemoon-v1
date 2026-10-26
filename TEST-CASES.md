# Тест-кейсы

Описание всех тестов репозитория: что проверяет кейс, какие инварианты покрывает и какой результат
должен получиться. При добавлении или изменении теста обновлять соответствующую строку.

- Юнит и end-to-end: `forge test --no-match-path "test/fork/*"` (`make unit-tests`).
- Форк девнета: `make devnet-tests ENVIRONMENT=dev`, нужны `DEVNET_RPC`, `DEVNET_BLOCK`, `OPERATOR_ADDRESS` в `env/dev.mk`.
- Пометка (fuzz) — fuzz-тест, invariant — инвариант-тест Foundry.

## test/ControllerDeployTokenTest.sol

End-to-end в процессе теста: настоящие PoolManager, PositionManager и Permit2, деплой через скрипт. Базовая ставка мема 1.25%, доля протокола четверть комиссии, 2500 bips (если не сказано иное).

### Создание мема и позиция

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_DeployToken_MintsWholeSupplyIntoPositionOwnedByController` | Деплой мема без dev buy | Вся эмиссия в позиции, NFT позиции у контроллера, создатель без токенов | Ликвидность > 0, supply = 1 млрд, у контроллера < 1 токена пыли, у создателя 0, волт зарегистрирован |
| `test_DeployToken_TokenURI_DataJsonBase64` | ERC-1046 у мема из `deployToken` | Метаданные ончейн, без отдельного URI | `tokenURI()` начинается с `data:application/json;base64,` и не пуст |
| `test_DeployToken_NoAllowanceLeftBehind` | Апрувы после минта позиции | После деплоя контроллер не оставляет апрувов | ERC20-апрув на Permit2 = 0, Permit2-апрув на PositionManager = 0 |
| `test_DeployToken_EmitsPositionCreated` | Событие `PositionCreated` | Событие совпадает с реальной позицией | `token`, `positionId`, `liquidity` из события равны данным PositionManager |
| `test_DeployToken_Twice_IndependentPositions` | Два мема подряд | Позиции независимы | Разные адреса токенов, id позиций подряд, обе у контроллера |
| `test_DeployToken_RecordsHookOf` | Хук мема в контроллере | Контроллер помнит хук каждого мема | `hookOf(token)` = хук, у неизвестного адреса 0 |
| `test_SetHook_NewHook_OldMemeKeepsHookAndPaysOut` | Новый хук в волте и контроллере, старый и новый мем | Старый мем остаётся на старом хуке и получает выплаты; новый мем — на новом хуке | `hookOf` старого = старый хук, нового = новый; после двух покупок старого мема его комиссия в волте; комиссия нового мема взята новым хуком |
| `test_DeployToken_NotifiesHook_PoolTimestampIsBlockTimestamp` | Время создания пула в хуке | Окно анти-снайпа отсчитывается от блока деплоя | `poolTimestamps(token)` = `block.timestamp` деплоя |
| `testFuzz_DeployToken_TwoMemes_EachKeepsOwnPoolTimestamp` (fuzz) | Два мема в разное время | Время создания хранится отдельно по мему | У каждого мема своё время создания |
| `test_DeployToken_HookControllerIsOther_Revert` | Хук привязан к другому контроллеру | `notifyPoolCreated` только от контроллера | revert `NotController` |
| `test_DeployToken_PositionManagerNotSet_Revert` | Контроллер без PositionManager | Деплой невозможен в полунастроенном состоянии | revert `PositionManagerNotSet` |
| `test_SetPositionManager_ZeroAddress_Revert` | Нулевые адреса в `setPositionManager` | Нельзя сломать связку нулём | revert `InvalidAddress` для обоих параметров |
| `test_SetPositionManager_NotOwner_Revert` | `setPositionManager` не от владельца | Доступ только владельцу | revert |

### Путь комиссии

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_Swap_FirstBuy_FeeStaysAccruedUntilPoolManagerHoldsPairToken` | Первая покупка в пустом PoolManager | Неудачная выплата не ломает своп, комиссия не теряется | Трейдер получил мем, комиссия в `pendingFees`, протокол и волт пока 0 |
| `test_Swap_SecondBuy_PaysOutBothFeesSplitBetweenProtocolAndVault` | Вторая покупка выплачивает обе комиссии одной выплатой, делит волт | Протокол + волт = вся взятая комиссия, протоколу четверть выплаты | `pendingFees` = 0, протокол = floor(сумма × 2500 / 10000), волт остальное, `vault.accounted` = доля волта |
| `test_Distribute_AfterFirstBuy_PaysAccruedFee` | Ручная выплата `distribute` | Начисленное выплачивается полностью и с тем же делением | `pendingFees` = 0, деление протокол/волт как у автоматической выплаты |

### Стартовая цена

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_DeployToken_StartPrice_InitialPriceMemePerWholePairToken` | Покупка на 1 USDG | Стартовая цена 50 000 мемов за 1 USDG при 6 знаках USDG | Получено меньше 50 000 мемов, но потери на комиссию и импакт < 3.3% |
| `test_DeployToken_StartMarketCap_TwentyThousandPairTokens` | Константы стартовой цены | Стартовая капитализация 20 000 USDG, цена точная | `INITIAL_MARKET_CAP` = 20 000, `PRICE_PER_TOKEN` = 50 000, эмиссия / цена = 20 000 |
| `test_DeployToken_PoolInitializedAtPriceForPairDecimals` | `sqrtPriceX96` пула | Цена учитывает decimals обоих токенов | slot0 равен расчёту `PriceMath` |

### Событие `MemeSwapped`

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_Swap_BuyExactIn_EmitsMemeSwapped` | Покупка exact input | `pairAmount + fee` = введённая сумма | Поля события верны, `router` = роутер, `trader` = 0 без hookData |
| `test_Swap_BuyExactOut_EmitsMemeSwapped` | Покупка exact output | Покупатель платит `pairAmount + fee` | `memeAmount` = запрошенному, `fee` от `pairAmount` |
| `test_Swap_SellExactIn_EmitsMemeSwapped` | Продажа exact input | Продавец получает `pairAmount - fee` | `isBuy` = false, `fee` от `pairAmount` |
| `test_Swap_SellExactOut_EmitsMemeSwapped` | Продажа exact output | Продавец получает ровно запрошенный USDG | `pairAmount` = выход + комиссия |
| `test_Swap_HookDataAddress_ReportedAsTrader` | Адрес в `hookData` | `trader` берётся из hookData | `trader` = переданный адрес |
| `test_Swap_HookDataWrongLength_TraderZero` | `hookData` не 32 байта | Мусор в hookData игнорируется | `trader` = 0 |
| `testFuzz_Swap_FeeIsAlwaysCharged` (fuzz) | Две покупки на любую сумму | Протокол + волт = 1.25% от всего объёма | Всё выплачено, сумма выплат = сумма комиссий |

### Анти-снайп комиссия

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_Swap_BuyAtLaunch_ChargesMaxFee` | Покупка в момент создания | В момент создания ставка 80% | `fee` = 80% входа, вся в `pendingFees` |
| `test_Swap_BuyHalfWindowAfterLaunch_ChargesMidpointFee` | Покупка в середине окна | Ставка падает линейно | `fee` = линейная середина между 80% и базовой |
| `test_Swap_SellAtLaunch_ChargesMaxFeeOnOutput` | Продажа в момент создания | Анти-снайп и на продажу | `fee` = 80% от выхода пула |
| `test_Swap_BuyOneMinuteAfterLaunch_ChargesBaseFee` | Покупка после окна | После окна только базовая ставка | `fee` = 1.25% |
| `testFuzz_Swap_DynamicFee_ProtocolPlusVaultPlusAccruedEqualsCharged` (fuzz) | Две покупки в любые моменты окна | Протокол + волт + начислено = вся комиссия; протокол получает четверть выплаченного, включая анти-снайп надбавку; волт учитывает только свою часть; ставка не растёт со временем | Равенства сохраняются, протокол = floor(выплачено × 2500 / 10000), `vault.accounted` = доля волта |

### Ставка, выбранная создателем

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_DeployToken_SwapFee_StoredInHook` | Ставка 5% | Ставка создателя доходит до хука | `memeFeeBips` и `currentFeeBips` после окна = 500 |
| `test_DeployToken_SwapFeeBelowOnePercent_Revert` | Ставка 0.99% | Нижняя граница 1% | revert `InvalidMemeFeeBips(99)` |
| `test_DeployToken_SwapFeeAboveFivePercent_Revert` | Ставка 5.01% | Верхняя граница 5% | revert `InvalidMemeFeeBips(501)` |
| `test_DeployToken_CreatorShare_StoredInVault` | `vaultCreatorShareBps = 3500` | Доля создателя из конфига доходит до волта | `creatorShareBpsOf(token)` и `vaultInfo(token).creatorShareBps` = 3500 |
| `test_DeployToken_CreatorShareAboveCap_Revert` | `vaultCreatorShareBps = 5001` | Доля создателя ≤ 50% (`MAX_CREATOR_SHARE_BPS`) | revert `InvalidCreatorShare(5001)`, мем не создан |
| `test_DeployToken_CreatorShareAboveBps_Revert` | `vaultCreatorShareBps = 10001` | Доля создателя ≤ 50% | revert `InvalidCreatorShare(10001)`, мем не создан |
| `test_DeployToken_CreatorShareMaxUint16_RevertsWithVaultError` | `vaultCreatorShareBps = 65535` | Расчёт `feeInfo` не падает раньше волта на неверной доле | revert `InvalidCreatorShare(65535)` |
| `test_DeployToken_FeeInfo_WrittenIntoToken` | `feeInfo()` мема с комиссией 1.25%, доля протокола 2500, доля создателя 1000 | Распределение записано в токен при деплое | total 12 500, protocol 3 125, creator 937, vault 8 438 ppm |
| `testFuzz_DeployToken_FeeInfo_MirrorsHookAndVault` (fuzz) | Любая комиссия 100..1000 bips и доля создателя 0..10 000 | total = `baseFeeBips` хука × 100; protocol = total × `vault.protocolShareBps()` / 10 000; creator = (total − protocol) × доля создателя волта / 10 000; части в сумме = total | все равенства выполняются |
| `test_Swap_FivePercentFee_ProtocolGetsQuarterVaultRest` | Две покупки при 5% | Протокол получает четверть комиссии, волт остальное | Протокол 1.25% объёма (±1), волт остальное, сумма = 5% объёма |
| `test_Swap_ProtocolShare_QuarterOfAnyMemeFee` | Покупка на 1000 USDG при ставках 1%, 3%, 5% | Четверть комиссии протоколу при любой ставке | Протокол/волт = 1/4 и 3/4 комиссии (±1): при 1% 0.25%/0.75%, при 5% 1.25%/3.75% объёма |
| `testFuzz_Swap_AnySwapFee_ProtocolGetsQuarterFeeConserved` (fuzz) | Любая ставка 1%..5% | Комиссия сохраняется; протокол получает 2500 bps выплаты с округлением вниз, не больше четверти | Протокол + волт + начислено = вся комиссия; протокол = floor(выплачено × 2500 / 10000) |

### Dev buy

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_DeployToken_DevBuy_BuyerReceivesExactAmountAndPaysPairIn` | Dev buy 1% эмиссии | Покупатель получает ровно запрошенное и платит ровно `pairIn`; контроллер ничего не держит | Баланс мема = 1%, списано `pairIn`, у контроллера 0 USDG, апрув уменьшен ровно на `pairIn` |
| `test_DeployToken_DevBuy_ChargesBaseFeeNotSnipeFee` | Ставка dev buy при 5% | Dev buy платит базовую ставку, остальные анти-снайп | `fee` = 5% от `pairAmount`, `router` = контроллер, `trader` = покупатель; `currentFeeBips` = 80% |
| `test_DeployToken_DevBuy_FeeAccruedThenPaidByNextSwap` | Судьба комиссии dev buy | Комиссия dev buy не теряется | После деплоя в `pendingFees`, следующий своп выплачивает её вместе со своей |
| `test_DeployToken_DevBuy_SameBlockBuyPaysMaxFee` | Снайпер в том же блоке | Исключение работает только для контроллера | Покупка трейдера после dev buy платит 80% |
| `test_DeployToken_DevBuy_MovesPriceForLaterBuyers` | Цена после dev buy 80% | Dev buy двигает цену как обычная покупка | Следующий покупатель получает меньше мема за 1 USDG, чем dev в среднем |
| `test_DeployToken_DevBuyAtCap_Succeeds` | Dev buy ровно 80% | Лимит включительно, равен 80% эмиссии; стоимость ≈ 4× стартовой капитализации | Создатель получил `MAX_DEV_BUY_X18`; цена пула 80 000..85 000 USDG |
| `test_DeployToken_DevBuyAboveCap_Revert` | Dev buy 80% + 1 wei | Лимит 80% эмиссии | revert `DevBuyTooLarge(amount, max)` |
| `test_DeployToken_DevBuySlippage_Revert` | `maxPairIn` на 1 меньше стоимости, затем ровно стоимость | Слиппедж-защита покупателя | Сначала revert `DevBuySlippage(pairIn, pairIn-1)`, затем успех с ровно `pairIn` |
| `test_DeployToken_DevBuyWithoutApproval_Revert` | Нет апрува USDG | Без апрува покупка невозможна | revert, деплой откатывается целиком |
| `test_DeployToken_DevBuy_PaidByCallerNotByOtherApprover` | Чужой апрув на контроллер | Платит только `msg.sender` | revert, баланс чужого адреса не тронут |
| `test_DeployToken_NoDevBuy_NoSwap` | `memeAmount` = 0 | Без dev buy свопа нет | Нет событий `DevBuy` и `MemeSwapped`, у создателя 0 мема |
| `test_UnlockCallback_NotPoolManager_Revert` | Прямой вызов `unlockCallback` | Callback только от PoolManager | revert `NotPoolManager` |
| `testFuzz_DeployToken_DevBuy_ExactOutAtBaseFee` (fuzz) | Любой объём до 10% и любая ставка | Точный выход; `pairIn` = цена пула + базовая комиссия; комиссия сохраняется; у контроллера нет USDG | Все равенства выполняются |
| `testFuzz_DeployToken_DevBuy_CostMonotonic` (fuzz) | Два объёма `a <= b` | Купить больше не дешевле | `cost(a) <= cost(b)` |

#### Газ под конвертацию

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_Swap_CrossesThreshold_EnoughGas_ConvertsInSameSwap` | Своп, пересекающий порог, с лимитом 5M | Конвертация выполняется в том же свопе | Своп прошёл, `epoch` = 1, `pendingUSDG` = 0 |
| `test_Swap_CrossesThreshold_LowGas_RevertsWithNotEnoughGasForConversion` | Тот же своп с лимитом 300k | Своп не проходит с тихо упавшей конвертацией | Revert с внутренней ошибкой `NotEnoughGasForConversion`; эпоха, комиссия и баланс трейдера без изменений |
| `test_Swap_SellCrossesThreshold_ConvertsInSameSwap` | Продажа, пересекающая порог | Продажа запускает конвертацию так же, как покупка | `epoch` 1 → 2, `pendingUSDG` = 0 |
| `test_Swap_SellLowGas_RevertsWithNotEnoughGasForConversion` | Продажа с лимитом 300k | Проверка газа действует и на продажи | Revert `NotEnoughGasForConversion` |
| `test_Swap_BelowThreshold_LowGas_RevertsToo` | Лимит 300k, порог далеко | Требование действует и до порога | Revert `NotEnoughGasForConversion` |
| `test_Swap_ConversionOff_LowGas_Succeeds` | Лимит 300k, порог 0 | Без автоконвертации лишнего газа не нужно | Своп прошёл |
| `test_Swap_VaultReportsHugeConversionGas_CappedSwapSucceeds` | Волт сообщает `type(uint256).max` газа под конвертацию, своп с лимитом 5M | Ответ волта не может заблокировать торговлю (`MAX_CONVERSION_GAS`) | Своп прошёл |
| `test_Swap_VaultBurnsAllGas_SwapStillSucceeds` | Владелец ставит хуку vault, который сжигает весь газ (и в `conversionGasRequired`, и в выплате); своп с лимитом 5M | Ни один ответ или поведение vault не блокирует торговлю: вызовы vault ограничены по газу | Своп прошёл, выплата упала внутри try/catch, комиссия осталась накопленной |
| `testFuzz_Swap_AnyReportedConversionGas_SwapWithCapGasSucceeds` (fuzz) | Любой ответ `conversionGasRequired`, лимит 5M | Требуемый газ ограничен капом при любом ответе волта | Своп всегда проходит |
| `test_Swap_EstimatedBelowThreshold_OthersFillIt_EstimateStillEnough` | Газ оценён при далёком пороге (минимальный лимит, как `eth_estimateGas`), затем чужая сделка набирает порог почти до конца, наш своп его пересекает | Оценка газа не устаревает из-за чужих сделок | Своп с прежней оценкой прошёл и закрыл эпоху |
| `testFuzz_Swap_CrossesThreshold_AnyGas_ConvertsOrReverts` (fuzz) | Любой лимит 150k..3M | Своп, пересёкший порог, либо закрывает эпоху, либо откатывается целиком | Успех ⇒ `epoch` = 1 и нет `ConversionFailed`; откат ⇒ состояние не изменилось |

## test/DeployGemoonFullTest.sol

Полный деплой `DeployGemoon.deployFull` / `run`: Vault, GemoonController, GmoonReferrals, HookManager, UniswapV3SwapAdapter, наградные активы с маршрутами, владение, отчёт. Uniswap V3 — моки `MockV3Factory` / `MockV3Pool` (fee tier 3000, история TWAP включается флагом), окно 600 с, допуск 100 bps.

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_DeployFull_Wiring_AllContractsPointAtEachOther` | Связка всех пяти контрактов | Каждый указывает на нужных соседей, рефералы — получатель протокольной доли | `checkWiring`, `checkReferralsWiring`, `checkAdapterWiring` проходят; `vault.protocolRecipient = referrals`, `referrals.vault = vault`, `vault.protocolShareBps = 2500`, `vault.swapAdapter = adapter`, параметры адаптера и рефералов из params |
| `test_DeployFull_Ownership_TwoStepPendingUntilAccepted` | Передача владения при `owner ≠ deployer` | Ownable2Step не отдаёт владение без accept; ProxyAdmin у `proxyAdminOwner` | Контроллер и хук сразу у owner; vault, referrals, adapter — pending до `acceptOwnership`, после — у owner; ProxyAdmin vault, controller, referrals у `proxyAdminOwner`; у хука ProxyAdmin нет |
| `test_DeployFull_OwnerIsDeployer_NothingPending` | Владелец = деплоер | Нет лишних pending-передач | Все контракты у деплоера, `pendingOwner = 0` |
| `test_DeployFull_RoutableAssets_AllowedAndRouted` | Активы с фабричным пулом и историей TWAP | Разрешён ⇔ есть маршрут на пул из файла | Статус `Routed`, актив в allowlist, маршрут: пул, fee 3000, допуск 100; allowlist = 2 |
| `test_DeployFull_UnroutableAssets_SkippedWithReason` | Актив без кода, без пула, чужой пул, пул без истории, сам USDG | Неконвертируемый актив не попадает в allowlist | Статусы `NoCode`, `NoPool`, `NotFactoryPool`, `NoTwapHistory`, `PairToken`; маршрутов нет; разрешён только USDG |
| `test_ConfigureAssets_SameRowTwice_SendsNothingNew` | Повторный прогон тех же строк | Идемпотентность: без изменений — без транзакций | Повтор не эмитит событий; новый допуск перезаписывает только маршрут (200) |
| `test_ConfigureAssets_NotOwner_Revert` | Настройка активов после передачи владения | Allowlist меняет только владелец волта | revert |
| `test_CheckAssets_RouteMissing_Revert` | Маршрут удалён после настройки | Проверка ловит рассинхрон allowlist и маршрутов | revert `WiringMismatch("route: AAPL")` |
| `testFuzz_ConfigureAssets_AllowedIffRoutable` (fuzz) | 6 строк со случайным видом (маршрутизируемый, без пула, чужой пул, без истории, без кода) | Актив разрешён ⇔ маршрутизируем; маршрут ⇔ маршрутизируем и ведёт на пул из файла; размер allowlist = числу маршрутизируемых | Статус, allowlist, маршрут и размер allowlist совпадают с видом каждой строки; `checkAssets` проходит |
| `test_ParseAssets_Csv_SkipsHeaderAndBlankLines` | Разбор CSV с `\r\n`, пробелами, пустой строкой и пустой колонкой пула | Заголовок и пустые строки не дают строк | 2 строки, тикеры и адреса без пробелов, пустой пул = 0 |
| `test_ParseAssets_RowWithoutAddress_Revert` | Строка без колонки адреса | Битый файл не проходит молча | revert `InvalidAssetRow(2)` |
| `test_ParseAssets_RepoAssetFile_AllRowsHaveAssetAndPool` | Реальный `tools/scripts/robinhood-assets.csv` | Файл в репозитории разбирается целиком | Все строки с тикером, адресом актива и пула |
| `test_BuildReport_ListsContractsOwnershipAndAssets` | Отчёт деплоя | В отчёте есть всё, что нужно оператору | Адреса пяти контрактов, строка актива, причина пропуска, to-do `acceptOwnership`, итог «Allowed: 1, skipped: 1» |
| `test_Run_FromEnv_DeploysWiresAndWritesReport` | `run()` из env, активы из файла, отчёт в файл | Пустые env-переменные = значения по умолчанию | Связка проходит; комиссия хука 300, доля протокола 2500, реферера 2500, окно 600, допуск 100; актив из файла и USDG из `VAULT_ALLOWED_ASSETS` разрешены; ProxyAdmin у `GEMOON_OWNER`; отчёт записан и содержит адаптер |

## test/fork/ControllerDevnetForkTest.sol

Девнет: anvil-форк Robinhood Chain (chain id 1488) с его Uniswap V4 (адреса из `env/dev.mk`, по умолчанию зашиты в тест), mock USDG. Запуск `make devnet-tests`, без `DEVNET_RPC` пропускается.

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_Fork_Deployment_WiredAgainstDevnetUniswap` | Связка после деплоя скриптом | Контроллер и хук смотрят на канонические адреса Uniswap девнета | `checkWiring` проходит, адреса PoolManager/PositionManager/Permit2 верны |
| `test_Fork_Deployment_OwnedByDevnetAccount` | Владение после деплоя | Владение уходит на аккаунт девнета, волт в два шага | Хук и контроллер у аккаунта, волт после `acceptOwnership` |
| `test_Fork_DeployToken_MintsPositionOnDevnetPositionManager` | Деплой мема на девнете | Вся эмиссия в позиции контроллера, апрувов не осталось | NFT у контроллера, ликвидность > 0, у создателя 0, апрувы 0 |
| `test_Fork_DeployToken_PoolInitializedWithHookAtExpectedPrice` | Ключ пула и цена | Пул с нашим хуком, LP fee 0, позиция односторонняя | Ключ пула верен, цена = расчётной, диапазон по ту сторону тика |
| `test_Fork_DeployToken_Buy_TraderReceivesMemeAndHookChargesFee` | Покупка после окна | Хук берёт базовую комиссию | Трейдер получил мем, `pendingFees` = 1.25% |
| `test_Fork_DeployToken_Twice_IndependentPositions` | Два мема | Позиции независимы | Разные токены, id подряд, оба волта зарегистрированы |

## test/fork/DevBuyDevnetForkTest.sol

Сквозной dev buy на девнете. Ставка мема 3%, доля протокола четверть комиссии (2500 bips), наградный актив сам USDG (на форке нет V3-пулов для mock USDG), порог конверсии 1 USDG.

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_DeployToken_DevBuyThreePercent_CreatorHoldsThreePercentAndFeeAccrued` | Деплой с dev buy 3% эмиссии | Создатель получает ровно 3%; платит цену пула + базовую ставку, не 80%; комиссия не теряется | Баланс = 3% эмиссии, списано `pairIn` = `pairAmount + fee`, комиссия в `pendingFees`, у контроллера 0 USDG |
| `test_Distribute_AfterDevBuy_FeeReachesVaultAndProtocolAndClosesEpoch` | `distribute` после dev buy | Хук отдаёт всё волту, волт отправляет протоколу четверть, остальное оставляет; порог закрывает эпоху | Протоколу четверть комиссии dev buy, волту остальное, эпоха 0 закрыта, всё создателю (стейкеров нет) |
| `test_DeployToken_DevBuyThenTrading_FeesConvertedOverSeveralEpochs` | Dev buy, стейк половины, две покупки после окна | Протокол получил ровно четверть (2500 bps) каждой выплаты (первая сделка выплачивает комиссию dev buy вместе со своей), dev buy включительно; волт остальное и должен всё создателю и стейкерам; каждая выплата закрывает эпоху | Закрыты 2 эпохи, суммы протокола и волта точные, создатель забирает всё через `claim` и `claimCreatorRewards`, в волте ≤ 2 wei пыли |

## test/GemoonLensTest.sol

End-to-end в процессе теста: настоящие PoolManager/PositionManager/Permit2, протокол через скрипт деплоя, пять наградных активов в allowlist (USDG и четыре mock-токена с decimals 8/18/6/2), Lens поверх деплоя. Номера в скобках — кейсы раздела 6 ТЗ.

Инварианты Lens (общие для всех кейсов):
- **L1** Ни одна функция не ревертит из-за входных адресов: результат на каждый вход, в том же порядке.
- **L2** Элемент батча `i` равен вызову с одним элементом `[memes[i]]`: соседи не влияют друг на друга.
- **L3** Каждое поле совпадает с прямым чтением протокола (vault, hook, token, slot0 PoolManager).
- **L4** Неудачное чтение даёт ноль, а где ноль допустим — флаг `false`; вызовы по аккаунту и волту не выполняются, если `account == 0` или мем не зарегистрирован.

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_Constructor_ZeroAddress_Revert` | Нулевой адрес в конструкторе | Lens не создаётся над пустыми адресами | revert `ZeroAddress` для каждого из четырёх параметров |
| `test_Constructor_StoresAddresses` | Адреса конструктора | Lens читает тот деплой, для которого создан | `controller()`, `vault()`, `protocol().hook/poolManager` = переданным |
| `test_Tokens_RegisteredMemeNoAccount_MatchesDirectReads` (1) | Мем с 5 ассетами и соцсетями после двух покупок и сжигания на `0xdEaD`, без аккаунта | L3, L4 | meta/market/vault равны `name/symbol/decimals/description/imageAddress/creator/getSocialMedia`, `totalSupply`, `balanceOf(0x0)+balanceOf(dEaD)`, `getSlot0(poolId)`, `pendingFees`, `vaultInfo` (включая `creatorShareBps` = 1000), `getAssets` + symbol/decimals ассетов; все флаги `true`; `position` нулевая |
| `test_Tokens_FeeAccruedInHook_PendingFeesMatchHook` | Первая покупка, комиссия осталась в хуке | L3 | `market.pendingFees` = `hook.pendingFees(meme)` > 0 |
| `test_Tokens_AssetWithBrokenMetadata_AssetFlagsFalse` | Ассет из allowlist с ревертящим `symbol()` и `decimals()` = 256 | L4 | У сломанного ассета `symbolOk`/`decimalsOk` = `false`, нули; у USDG флаги `true`, decimals 6 |
| `test_Tokens_HookPendingFeesReverts_PendingFeesOkFalse` | `hook.pendingFees` ревертит (mock) | L4 | `pendingFeesOk = false`, `pendingFees` = 0, остальное читается |
| `test_Tokens_IsRegisteredReverts_RegisteredOkFalse` | `vault.isRegistered` ревертит (mock) | L4 | `registeredOk = false`, `registered = false`, вызовы волта в `vault` и `position` пропущены |
| `test_Tokens_StakerAccount_PositionMatchesVault` (2) | Аккаунт со стейком, сконвертированной наградой и кредитом открытой эпохи | L3 | `balance`, `staked`, `pendingCredit` > 0, `allowance` = 777, `earned` (> 0) совпадают с прямыми вызовами |
| `test_Tokens_UnregisteredToken_VaultZeroNoRevert` (3) | Обычный ERC20 без волта | L1, L4 | `meta.ok`, `vault` нулевой кроме `registered = false` и `registeredOk = true` (волт ответил), `position.balance` из токена, поля волта в позиции 0 |
| `test_Tokens_HookReplaced_EachMemeReadThroughItsHook` | Хук заменён, есть мем на старом и на новом хуке | Lens читает каждый мем через его хук (`controller.hookOf`) | `poolId` нового мема — ключ с новым хуком, цена > 0; старый мем — ключ со старым хуком |
| `test_Tokens_PoolNotCreated_SqrtPriceZeroPoolIdComputed` (6) | Токен без пула | L4 | `sqrtPriceX96` = 0, `poolId` = id ключа `sort(USDG, token), 0, 200, hook` |
| `test_Tokens_EoaInBatch_MetaNotOkOthersCorrect` (4) | EOA между двумя мемами | L1, L2 | У EOA `meta.ok = false`, нули, `poolId` посчитан; соседние элементы равны одиночным вызовам |
| `test_Tokens_TokenWithoutCreatorOrDecimals_FlagsFalse` (5) | Токен без метаданных, `creator()` и `getSocialMedia()` | L4 | `decimalsOk`, `creatorOk`, `socialOk` = `false`, строки пустые, `burnedOk` = `true` (`balanceOf` есть), батч не падает |
| `test_Tokens_MalformedReturnData_FlagsFalseNoRevert` (5) | Ответы, не декодируемые как стандартные типы: `bytes32`-имя, revert, `decimals` = 256, `creator` > 160 бит, длина и offset строки за пределами данных, член `getSocialMedia` за пределами данных, нет `balanceOf` | L1, L4 | Все флаги `false` (включая `socialOk`, `burnedOk`), строки и соцсети пустые, мем в том же батче равен одиночному вызову |
| `test_Tokens_TotalSupplyReverts_MetaNotOk` | `totalSupply()` ревертит | L4 | `meta.ok = false`, остальное нули, `position` не заполняется |
| `test_Tokens_EmptyInput_EmptyOutput` | Пустой массив | L1 | Пустые массивы из `tokens` и `markets` |
| `test_Tokens_LongStrings_ReturnedWhole` | Описание и картинка по 2 КБ | L3 | Строки возвращаются целиком |
| `test_Tokens_DuplicatesAndOrder_ThreeElementsSameOrder` (10) | `[a, b, a]` | L1, L2 | Три элемента в том же порядке, первый и третий идентичны |
| `test_Markets_MatchTokensMarketAndVaultTotalStaked` | `markets` и `totalStaked` на мемах и EOA | L2, L3 | `market[i]` = `tokens(...)[i].market`, `staked[i]` = `vault.totalStaked`, `totalStaked(list)` = `staked` |
| `test_Quotes_AssetWithoutRoute_OkFalseOthersQuoted` (7) | Адаптер с маршрутами для двух ассетов из трёх | L1, L4 | Без маршрута `ok = false`, 0; остальные `amountIn * rate`; USDG 1:1 |
| `test_Quotes_NoAdapter_AllOkFalseExceptUsdg` | Адаптер не задан | L1 | Ассет `ok = false`, USDG 1:1 |
| `test_Quotes_AdapterIsEoa_OkFalseNoRevert` | Адаптер — адрес без кода | L1 | `ok = false`, без revert |
| `test_Protocol_MatchesVaultAndHook` (8) | `protocol()` | L3 | USDG = `vault.usdg()` = `hook.pairToken()`, decimals 6, symbol, адаптер, порог 5e6, cooldown, хук, PoolManager |
| `test_Creator_MatchesVault` | Доля создателя после конвертации | L3 | `creatorOf`, `assets`, `accrued` (> 0) = `vault.creatorOf/creatorAccrued` |
| `test_Creator_Unregistered_Zero` | Неизвестный мем | L1 | Нулевой создатель, пустые массивы |
| `test_Creators_Batch_EachEqualsCreator` | `creators([a, неизвестный, b, a])` | L1, L2, L3 | 4 элемента, каждый равен `creator(meme)`, `ok = true`, у `a` начислено > 0 |
| `test_Creators_VaultReverts_OkFalseNoRevert` | `creatorAccrued` ревертит (mock) | L1, L4 | `ok = false`, `creatorOf` всё равно заполнен, массивы пустые |
| `testFuzz_Creators_AnyAddresses_OnePerInput` (fuzz) | До 16 любых адресов | L1, L3 | Элемент на каждый вход, `creatorOf` = `vault.creatorOf` |
| `test_DeployLens_Create2_DeterministicAndRepeatable` | Скрипт деплоя дважды | Адрес детерминирован, повторный запуск ничего не деплоит | Адрес = `predict`, второй запуск возвращает тот же адрес |
| `test_DeployLens_WiringMismatch_Revert` | PoolManager не тот, что у хука | Lens не деплоится над несвязанными контрактами | revert `WiringMismatch("hook.poolManager")` |
| `testFuzz_Tokens_AnyAddresses_NeverRevertsOnePerInput` (fuzz) | До 16 любых адресов (EOA, прекомпайлы, cheatcodes, контракты) и любой аккаунт | L1 | `tokens` и `markets` возвращают по элементу на вход, не-токен никогда не `registered` |
| `testFuzz_Tokens_BatchElementEqualsSingleCall` (fuzz) | Случайная смесь мемов, обычного, сломанного и пустого токена и EOA с повторами | L1, L2 | Каждый элемент батча побайтно равен одиночному вызову |
| `testFuzz_Tokens_Burned_SumOfBurnAddresses` (fuzz) | Любая сумма на `0xdEaD` | L3 | `burned` = переведённая сумма |

### Газ (GemoonLensGasTest, кейс 9)

Мемы создаются в `setUp`, поэтому в замеряемом вызове все аккаунты и слоты холодные, как в `eth_call`. У каждого мема 5 ассетов, аккаунт держит и стейкает каждый.

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_Gas_Tokens70WithAccount_Below30M` | 70 мемов, аккаунт, соцсети, строки 280/120 Б | Лимит ТЗ 30M | 18.4M < 30M |
| `test_Gas_Tokens70NoAccount_Below30M` | То же без аккаунта | Лимит ТЗ 30M | 14.5M < 30M |
| `test_Gas_Tokens70WithAccount2KbStrings_BelowNodeCap` | 70 мемов со строками по 2 КБ | Худший случай под лимитом ноды 50M | 40.8M < 50M (> 30M, отсюда чанк 50) |
| `test_Gas_Tokens50WithAccount2KbStrings_Below30M` | Чанк 50 со строками по 2 КБ | Рекомендуемый чанк держит 30M | 27.5M < 30M |
| `test_Gas_Markets200_Below15M` | `markets(200)` | Лимит ТЗ 15M | 6.0M < 15M |
| `test_Gas_TotalStaked200_Below15M` | `totalStaked(200)` | Лимит ТЗ 15M | 1.4M < 15M |

## test/fork/GemoonLensDevnetForkTest.sol

Девнет: Anvil-форк Robinhood (chain id 1488) с развёрнутым протоколом, адреса из ТЗ. Lens деплоится внутри форка, ничего не отправляется. Мемы — последние 70 CREATE контроллера. Без `DEVNET_RPC` или на другой сети пропускается.

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_Tokens_DevnetMemes_MatchDirectReadsAndStateView` | 5 реальных мемов | L3, цена совпадает с периферийным `StateView` | `sqrtPriceX96` = `StateView.getSlot0(poolId)` > 0, supply, burned, `pendingFees`, соцсети, `vaultInfo`, `getAssets` совпадают, все флаги `true` |
| `test_Creators_DevnetMemes_MatchVault` | `creators` на 70 реальных мемах | L3 | Все `ok`, `creatorOf` = `vault.creatorOf` |
| `test_Protocol_Devnet_MatchesVault` | `protocol()` на девнете | L3 | USDG, адаптер, хук, PoolManager = реальным |
| `test_Quotes_DevnetAllowlist_AllQuoted` | Котировки всего allowlist через реальный адаптер | У каждого разрешённого ассета есть маршрут | Все `ok`, суммы > 0 |
| `test_Gas_Tokens70Devnet_Below30M` | `tokens(70, account)` на реальных мемах | Лимит ТЗ 30M на реальных данных | 14.2M < 30M |

## test/ReferralsTest.sol

Юнит-тесты `GmoonReferrals` за прокси, mock USDG (6 dec). Тест играет хук (источник комиссий старой схемы), волт и контроллер через `prank`. `refShareBips` = 1000 (10%). alice — реферер с кодом `alice`, bob привязан к нему и деплоит `meme`, carol без реферера.

### Инициализация и админ

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_Initialize_Valid_StoresConfig` | Конфиг после `initialize` | Прокси настроен одной транзакцией | owner, pairToken, controller, hook, refShare, версия 1 |
| `test_Initialize_Twice_Reverts` | Повторный `initialize` | Инициализация один раз | revert |
| `test_Initialize_Implementation_Reverts` | `initialize` имплементации | Имплементация не инициализируется | revert |
| `test_Initialize_RefShareAboveBips_Reverts` | refShare > 100% | `refShareBips <= BIPS` | revert `InvalidRefShare` |
| `test_Initialize_ZeroControllerAndHook_LeftUnset` | Нулевые controller/hook | Их можно задать позже | оба 0 |
| `test_SetRefShare_AboveBips_Reverts`, `test_SetRefShare_NotOwner_Reverts` | `setRefShare` | Граница и доступ | revert `InvalidRefShare` / `OwnableUnauthorizedAccount` |
| `test_SetHook_Zero_Reverts`, `test_SetController_Zero_Reverts`, `test_SetHook_NotOwner_Reverts` | Сеттеры | Нельзя обнулить, только владелец | revert `ZeroAddress` / `OwnableUnauthorizedAccount` |
| `test_SetHook_NewHook_OldHookStillNotifies` | Смена хука | Хук не обновляемый: старые мемы платят через старый хук | `hook()` = новый, `isHook` для обоих, `notifyFee` от обоих зачислен (200 000 рефереру) |
| `testFuzz_SetHook_AnySequence_OnlySetHooksNotify` (fuzz) | Любая последовательность из 3 хуков и посторонний адрес | `notifyFee` принимается от любого когда-либо назначенного хука и ни от кого больше (волт не задан) | все хуки проходят, посторонний — `isFeeSource` false и revert `NotFeeSource` |
| `test_SetVault_StoresAndEmits` | `setVault` | Волт задаёт владелец | `vault()` = адрес, событие `VaultUpdated` |
| `test_SetVault_Zero_Reverts`, `test_SetVault_NotOwner_Reverts` | Ограничения `setVault` | Нельзя обнулить, только владелец | revert `ZeroAddress` / `OwnableUnauthorizedAccount` |
| `test_IsFeeSource_VaultUnset_ZeroAddressRejected` | Волт не задан | Нулевой адрес никогда не источник комиссий | `isFeeSource(0)` = false |
| `test_SetVault_Replaced_OldVaultRejected` | Смена волта | Источник — только текущий волт | старый волт revert `NotFeeSource`, новый проходит |

### Коды и привязка

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_RegisterCode_Valid_StoresOwner` | Регистрация кода | Код → владелец, по строке и по хешу | `codeOwner` = alice |
| `test_RegisterCode_Taken_Reverts` | Занятый код | Код уникален | revert `CodeTaken` |
| `test_RegisterCode_SeveralPerReferrer_AllOwned` | Несколько кодов у одного | Ограничения на число кодов нет | оба кода у alice |
| `test_RegisterCode_Empty_Reverts`, `test_RegisterCode_TooLong_Reverts`, `test_RegisterCode_MaxLength_Succeeds` | Длина | 1..32 символа | revert `InvalidCode` для 0 и 33, 32 проходит |
| `test_RegisterCode_Uppercase_Reverts`, `test_RegisterCode_Space_Reverts` | Алфавит | Только `[a-z0-9_-]`, одно написание кода | revert `InvalidCode` |
| `testFuzz_RegisterCode_InvalidChar_Reverts` (fuzz) | Любой байт вне алфавита | Ни один посторонний символ не проходит | revert `InvalidCode` |
| `test_UseCode_Valid_SetsReferrer` | Привязка по коду | user → владелец кода, событие | `referrerOf(bob)` = alice, `ReferrerSet` |
| `test_UseCode_ManyUsersOneCode_AllReferredBySameReferrer` | Один код, три пользователя | По одному коду приводится сколько угодно пользователей | все три привязаны к alice, она получает 10% с мема каждого |
| `test_UseCode_Unknown_Reverts` | Несуществующий код | — | revert `CodeNotFound` |
| `test_UseCode_Own_Reverts` | Свой код | Нельзя привести себя | revert `SelfReferral` |
| `test_UseCode_Twice_Reverts` | Повторная привязка | Реферер один и навсегда | revert `ReferrerAlreadySet`, реферер прежний |

### Регистрация мемов

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_RegisterToken_NotController_Reverts` | Не контроллер | Только контроллер | revert `NotController` |
| `test_RegisterToken_ReferredCreator_StoresReferrer` | Мем приведённого | Мем → реферер создателя | `memeReferrer` = alice, `TokenRegistered` |
| `test_RegisterToken_CreatorWithoutReferrer_NoReferrer` | Мем без реферера | — | `memeReferrer` = 0 |
| `test_RegisterToken_ReferrerBoundLater_OldMemeStaysUnattributed` | Привязка после деплоя | Реферер фиксируется на момент деплоя | старый мем без реферера, новый за alice |

### Начисление (`notifyFee`)

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_NotifyFee_NotFeeSource_Reverts` | Не волт и не хук | Только источник комиссий (`isFeeSource`) | revert `NotFeeSource` |
| `test_NotifyFee_FromVault_CreditsRefShare` | `notifyFee` от волта | Волт — основной источник протокольной доли | `isFeeSource(vault)`, рефереру 100 000, протоколу 900 000 |
| `test_NotifyFee_ReferredMeme_CreditsRefShare` | Комиссия мема реферала | 10% рефереру, остальное протоколу | pending 100 000, protocolBalance 900 000, `FeeReceived` |
| `test_NotifyFee_MemeWithoutReferrer_AllToProtocol` | Мем без реферера | Всё протоколу | totalPending 0 |
| `test_NotifyFee_UnregisteredMeme_NoRevertAllToProtocol` | Неизвестный мем | Не блокирует выплату хука | без revert, всё протоколу |
| `test_NotifyFee_WithoutTransfer_Reverts` | Уведомление без перевода | `balance >= totalPending` | revert `BalanceTooLow` |
| `test_NotifyFee_SameTransferReportedTwice_RevertsOnceDebtExceedsBalance` | Повторное уведомление | Долг не может превысить баланс | второй вызов revert `BalanceTooLow` |
| `test_NotifyFee_DustBelowShare_NothingCredited` | Пыль | Округление вниз в пользу протокола | pending 0 |
| `test_NotifyFee_ZeroRefShare_AllToProtocol`, `test_NotifyFee_FullRefShare_AllToReferrer` | Границы доли | 0% и 100% | всё протоколу / всё рефереру |
| `test_NotifyFee_RefShareChanged_AppliesToNewFeesOnly` | Смена доли | Действует на новые комиссии | 100 + 500 = 600 |
| `testFuzz_NotifyFee_SplitsExactly` (fuzz) | Любая сумма и доля | Реферер = floor(amount·share/BIPS), остальное протоколу, сумма = баланс | точное деление |

### Выплаты, пауза, протокол

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_Claim_Pending_PaysAndResets` | `claim` | Выплата обнуляет долг, earned сохраняется, доля протокола не трогается | alice 100 000, pending 0 |
| `test_Claim_Nothing_Reverts`, `test_Claim_Twice_SecondReverts` | Нечего забирать | Нет двойной выплаты | revert `NothingToClaim` |
| `test_Distribute_SeveralReferrers_PaysEach` | `distribute` от кипера | Каждому своё, дубли и нули пропускаются | alice 100, carol 300, totalPending 0 |
| `test_Distribute_Empty_ReturnsZero` | Пустой список | — | 0 |
| `test_SetPaused_NotOwner_Reverts`, `test_SetPaused_Twice_NoOp` | `setPaused` | Только владелец, повтор — no-op | revert / состояние как задано |
| `test_Claim_Paused_Reverts`, `test_Distribute_Paused_Reverts` | Выплаты на паузе | Пауза останавливает выплаты рефералам | revert `EnforcedPause` |
| `test_Paused_CreditAndProtocolWithdrawKeepWorking_ClaimAfterUnpause` | Пауза | Начисление и вывод протокола работают всегда; долг рефералам не трогается | начислено 100 000, протокол вывел 900 000, после снятия паузы alice получила 100 000 |
| `test_WithdrawProtocolFees_Owner_SendsBalanceMinusDebt` | Вывод протокола | Протокол забирает всё, кроме долга рефералам, включая прямые переводы | 900 005 протоколу, 100 000 остаются и выплачиваются alice |
| `test_WithdrawProtocolFees_NotOwner_Reverts`, `_Nothing_Reverts`, `_ZeroTo_Reverts` | Ограничения вывода | Только владелец, не в ноль | revert |
| `test_RescueERC20_OtherToken_Sends`, `_PairToken_Reverts`, `_NotOwner_Reverts` | `rescueERC20` | Pair-токен не спасается мимо учёта долга | чужой токен выведен, USDG revert `PairTokenRescue` |
| `testFuzz_ClaimAndWithdraw_AnyOrder_EmptiesContract` (fuzz) | Любой порядок claim / withdraw | Каждый получает ровно своё, контракт пустеет | balance 0, totalPending 0 |

### Инварианты (ReferralsInvariantTest, handler: useCode / deployMeme / fee / claim / distribute / withdrawProtocol / setRefShare / setPaused)

| Тест | Инвариант |
|---|---|
| `invariant_BalanceCoversReferralDebt` | `balanceOf(referrals) >= totalPending` — каждому рефереру всегда хватает |
| `invariant_TotalPendingIsSumOfPending` | `totalPending` = сумма `pendingOf` по всем реферерам |
| `invariant_Conservation` | баланс = всё пришедшее − всё выплаченное, токены не создаются и не теряются |
| `invariant_EarnedEqualsPendingPlusPaid` | `earnedOf(r)` = `pendingOf(r)` + выплаченное r: начисления не теряются и не выплачиваются дважды |

## test/ReferralsIntegrationTest.sol

End-to-end: настоящие PoolManager и PositionManager, Gemoon через `DeployGemoon`, рефералы через `deployReferrals` и `WireReferrals`. Хук отдаёт всю комиссию волту, волт переводит протокольную долю рефералам. Комиссия 1.25%, протоколу 2500 bps (доля в волте), рефереру 2500 bips протокольной доли. alice — реферер, bob привязан к ней.

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_WireReferrals_Valid_EverythingPointsAtReferrals` | Связка после `wireReferrals` | Контроллер, волт и рефералы указывают друг на друга | `checkReferralsWiring` проходит, `vault.protocolRecipient` = рефералы, `referrals.vault` = волт |
| `test_CheckReferralsWiring_VaultPaysElsewhere_Reverts` | Волт платит протокол другому адресу | Проверка ловит битую связку | revert `WiringMismatch("vault.protocolRecipient")` |
| `test_CheckReferralsWiring_ReferralsPointAtOtherVault_Reverts` | Рефералы смотрят на другой волт | Проверка ловит битую связку | revert `WiringMismatch("referrals.vault")` |
| `test_SetReferrals_NotOwner_Reverts` | `setReferrals` не от владельца | Только владелец контроллера | revert |
| `test_DeployToken_ReferredCreator_MemeAttributedToReferrer` | `deployToken` приведённого | Контроллер регистрирует мем | `memeReferrer` = alice |
| `test_Swap_ReferredMeme_ReferrerEarnsRefShareOfProtocolFee` | Две покупки, claim, вывод протокола | В рефералы приходит ровно протокольная доля, рефереру 25% её | точные суммы, после claim и withdraw баланс 0 |
| `test_Swap_MemeWithoutReferrer_AllToProtocol` | Мем без реферера | Всё протоколу | totalPending 0 |
| `test_Distribute_AfterTrades_PaysReferrer` | `distribute` после торгов | — | alice получила начисленное |
| `test_DeployToken_ReferralsUnset_NotRegistered` | Рефералы выключены в контроллере | Ноль выключает регистрацию | `memeReferrer` = 0 |
| `test_Payout_ReferralsRejectsVault_FeesStayAccruedUntilFixed` | Рефералы откатывают `notifyFee` (mock) | Сбой получателя откатывает разбивку в волте и выплату хука, но не своп; комиссия не теряется | `PayoutFailed`, комиссия в хуке, у волта и рефералов 0, после починки `distribute` выплачивает |
| `test_Payout_ReferralsHookReplaced_VaultStillPaysProtocolShare` | Рефералы переключены на другой хук | Хук новой схемы с рефералами не связан: долю платит волт | `pendingFees` 0, реферер получил долю |
| `test_Payout_EoaProtocolRecipient_PaysWithoutNotify` | EOA как получатель в волте | Волт не уведомляет EOA | EOA получает протокольную долю |
| `test_Payout_ProtocolShareChangedInVault_AppliesToNextPayout` | Владелец волта меняет долю на 50% между сделками | Доля глобальная, хук не трогается, действует с ближайшей выплаты | рефералы = половина выплаты, волт — остальное |
| `test_Payout_FirstFeeWithStakerAndReferrer_FitsPayoutGasOverhead` | Первая выплата мема со стейкером и реферером (холодные слоты везде) | Самая тяжёлая выплата укладывается в `PAYOUT_GAS_OVERHEAD` и проходит с первого раза | нет `PayoutFailed`, `pendingFees` = 0, реферер и стейкеры начислены |
| `testFuzz_Swap_ReferredMeme_SplitConserved` (fuzz) | Любые объёмы сделок | Баланс рефералов = протокольная доля (±1 на выплату, вниз); credit ≈ floor(доля·25%) (±1 на выплату, вниз); credit + протокол = баланс | точное сохранение |
| `test_UpgradeReferrals_NewVersion_KeepsState` | Апгрейд на v2 | Состояние и владелец сохраняются, reinitialize | версия 2, pending и memeReferrer прежние |
| `test_UpgradeReferrals_NotProxyAdminOwner_Reverts` | Апгрейд не владельцем ProxyAdmin | — | revert |

## test/VaultTest.sol

Фикстура: USDG (6 dec), MEME, AAPL (1 USDG → 2 AAPL), WBTC (1 USDG → 1 WBTC). Веса по умолчанию 60/40 (AAPL/WBTC). Доля создателя по умолчанию (`CREATOR_SHARE_BPS` фикстуры) — 10%; тесты ниже задают её явно при регистрации.

### Регистрация хранилища

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_RegisterVault_NotController_Reverts` | Регистрация не от контроллера. | Регистрация только контроллером | Revert `NotController` |
| `test_RegisterVault_Valid_StoresConfig` | Корректная регистрация с весами 60/40. | — | `isRegistered = true`, `creatorOf = creator`, 2 актива, веса сохранены |
| `test_RegisterVault_Twice_Reverts` | Повторная регистрация того же мем-токена. | Конфиг хранилища неизменяем после регистрации | Revert `VaultAlreadyRegistered(meme)` |
| `test_RegisterVault_WeightsNotBps_Reverts` | Сумма весов 9 999 вместо 10 000. | Сумма весов = 10 000 bps | Revert `InvalidWeights` |
| `test_RegisterVault_AssetNotAllowed_Reverts` | Актив не из белого списка (сам MEME). | Только разрешённые активы | Revert `AssetNotAllowed(meme)` |
| `test_RegisterVault_DuplicateAsset_Reverts` | Один актив указан дважды. | Активы хранилища уникальны | Revert `DuplicateAsset(aapl)` |
| `test_RegisterVault_NoAssets_Reverts` | Пустой список активов. | Хотя бы один актив | Revert `InvalidAssetsLength` |
| `test_RegisterVault_CreatorShare_StoredAndEmitted` | Регистрация с долей создателя 25%. | Доля создателя хранится per-vault | `VaultRegistered(meme, creator, 2500, assets)`, `creatorShareBpsOf` и `vaultInfo.creatorShareBps` = 2500 |
| `test_RegisterVault_CreatorShareAboveBps_Reverts` | Доля 10 001 bps. | Доля создателя ≤ `MAX_CREATOR_SHARE_BPS` | Revert `InvalidCreatorShare(10001)` |
| `test_RegisterVault_CreatorShareAtCap_Stored` | Доля ровно 5000 bps. | Потолок включительный, `MAX_CREATOR_SHARE_BPS` = 5000 | Волт зарегистрирован, `creatorShareBpsOf` = 5000 |
| `test_RegisterVault_CreatorShareAboveCap_Reverts` | Доля 5001 bps. | Доля создателя ≤ 50% | Revert `InvalidCreatorShare(5001)` |
| `testFuzz_RegisterVault_CreatorShare_RevertsAboveCap` (fuzz) | Любая доля `uint16`. | Ни один волт не регистрируется с долей создателя выше 50%: стейкерам всегда не меньше половины | > 5000 — revert `InvalidCreatorShare(share)`, иначе доля сохранена как есть |
| `test_CreatorShareBpsOf_Unregistered_ReturnsZero` | Доля для незарегистрированного мема. | — | 0 |

### Приём комиссий

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_NotifyFees_NotHook_Reverts` | `notifyFees` не от хука. | Учёт комиссий только хуком | Revert `NotHook` |
| `test_SetHook_NewHook_OldHookStillNotifies` | Смена хука волта. | Хук не обновляемый: старые мемы платят через старый хук | `hook()` = новый, `isHook` для обоих, комиссии от обоих зачислены (3e6) |
| `testFuzz_SetHook_AnySequence_OnlySetHooksNotify` (fuzz) | Любая последовательность из 3 хуков и посторонний адрес. | `notifyFees` принимается от любого когда-либо назначенного хука и ни от кого больше | Все хуки проходят, посторонний — revert `NotHook` |
| `test_SetHook_Zero_Reverts` | `setHook(0)`. | Хук не нулевой | Revert `ZeroAddress` |
| `test_NotifyFees_UnregisteredMeme_Reverts` | Комиссия для незарегистрированного токена. | — | Revert `VaultNotRegistered(meme)` |
| `test_NotifyFees_WithoutTransfer_Reverts` | Уведомление без фактического перевода USDG. | Учтённое ≤ реальный баланс | Revert `UnaccountedBalanceTooLow(0, 1e6)` |
| `test_NotifyFees_SameTransferTwice_Reverts` | Повторное уведомление на тот же перевод. | Один перевод учитывается один раз | Revert `UnaccountedBalanceTooLow(0, 1e6)` |
| `test_NotifyFees_NoStakers_AllToCreator` | Комиссия при отсутствии стейкеров. | Без стейкеров всё идёт создателю | `pendingCreatorUSDG = 100e6`, `pendingStakerUSDG = 0` |
| `test_NotifyFees_WithStakers_TenPercentToCreator` | Комиссия при наличии стейкера, доля 10%. | Сплит 10% создателю / 90% стейкерам | Создатель 10e6, стейкеры 90e6, `pendingCreditOf(alice) = 90e6` |
| `test_NotifyFees_ZeroCreatorShare_AllToStakers` | Доля 0%, есть стейкер. | При доле 0 всё стейкерам | Создатель 0, стейкеры 100e6, `pendingCreditOf(alice) = 100e6` |
| `test_NotifyFees_MaxCreatorShare_HalfToCreator` | Доля 50% (потолок), есть стейкер. | При максимальной доле стейкеры получают половину | Создатель 50e6, стейкеры 50e6, credit alice 50e6 |
| `test_NotifyFees_ZeroCreatorShareNoStakers_AllToCreator` | Доля 0%, стейкеров нет. | Без стейкеров всё создателю при любой доле | `pendingCreatorUSDG = 100e6` |
| `testFuzz_NotifyFees_AnyCreatorShare_SplitConserved` (fuzz) | Любая доля 0..5000, любой объём и стейк. | toCreator + toStakers = комиссия; toCreator = floor(amount × share / BPS); credit единственного стейкера ≤ доли стейкеров (±1); доля неизменна | Все равенства выполняются |

### Разбивка комиссии: доля протокола

Хук отдаёт волту всю комиссию; `notifyFees` сразу переводит `protocolShareBps` получателю протокола и делит остаток между создателем и стейкерами. В фикстуре доля 0 и получатель не задан, кейсы ниже задают их явно.

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_ProtocolSplit_FreshVault_ShareZeroRecipientUnset` | Свежий волт. | После деплоя/апгрейда волт ведёт себя по-старому | `protocolShareBps = 0`, `protocolRecipient = 0` |
| `test_SetProtocolShare_Owner_SetsAndEmits` | Владелец задаёт долю 3333. | Доля — настройка владельца волта | `protocolShareBps = 3333`, `ProtocolShareUpdated(3333)` |
| `test_SetProtocolShare_AboveBps_Reverts` | Доля 10 001. | Доля протокола ≤ BPS | Revert `InvalidProtocolShare(10001)` |
| `test_SetProtocolShare_NotOwner_Reverts`, `test_SetProtocolRecipient_NotOwner_Reverts` | Сеттеры не от владельца. | Доступ только владельцу | Revert `OwnableUnauthorizedAccount` |
| `test_SetProtocolRecipient_Owner_SetsAndEmits` | Владелец задаёт получателя. | — | `protocolRecipient` = адрес, `ProtocolRecipientUpdated` |
| `test_SetProtocolRecipient_Zero_Reverts` | Нулевой получатель. | Получатель не нулевой | Revert `ZeroAddress` |
| `test_NotifyFees_ProtocolShare_SendsShareAndCreditsRest` | 100e6 при доле 3333, стейкер есть, доля создателя 10%. | Протокольная часть уходит сразу и не учитывается; остаток делится как раньше | EOA 33.33e6, в волте 66.67e6 = `accounted`, создатель 6.667e6, стейкеры 60.003e6; события `FeesNotified`, `ProtocolFeePaid` |
| `test_NotifyFees_ShareWithoutRecipient_Reverts` | Доля > 0, получатель не задан. | Протокольная доля не теряется и не уходит мему | Revert `ProtocolRecipientNotSet` (хук держит комиссию) |
| `test_NotifyFees_ShareRoundsToZeroWithoutRecipient_CreditsAll` | Доля 1 bps, сумма 9 999. | Нулевая протокольная часть не требует получателя | Всё в `pendingUSDG` |
| `test_NotifyFees_ContractRecipient_Notified` | Получатель-контракт. | Контракт уведомляется после перевода | Один `notifyFee(meme, 33.33e6)`, токены уже на балансе |
| `test_NotifyFees_RecipientReverts_WholeNotifyReverts` | Получатель откатывает `notifyFee`. | Сбой получателя откатывает весь `notifyFees` | Revert, `pendingUSDG = 0`, `accounted = 0` |
| `test_NotifyFees_FullProtocolShare_NothingCredited` | Доля 100%. | Мему ничего | Получатель 100e6, `pendingUSDG = 0`, `accounted = 0` |
| `test_SetProtocolShare_Changed_AppliesToNextNotify` | Доля 3333 → 5000 между уведомлениями. | Доля глобальная, действует со следующей выплаты | Получатель 33.33e6 + 50e6, мему 66.67e6 + 50e6 |
| `testFuzz_NotifyFees_AnyProtocolShare_SplitConserved` (fuzz) | Любая доля протокола 0..10000, доля создателя, сумма, стейк. | protocol + creator + stakers = сумма; protocol = floor(amount × share / BPS); `accounted` = сумма − protocol | Все равенства, баланс волта = `accounted` |

### Конвертация

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_ConvertFees_Nothing_Reverts` | Конвертация без накопленных комиссий. | — | Revert `NothingToConvert` |
| `test_ConvertFees_NotRegistered_Reverts` | Конвертация для незарегистрированного токена. | — | Revert `VaultNotRegistered(meme)` |
| `test_ConvertFees_SplitsByWeight` | 100 USDG делятся по весам 60/40 и свапаются. | Распределение по весам; USDG полностью израсходован | 120 AAPL и 40 WBTC; создатель 12 AAPL / 4 WBTC; alice 108 AAPL / 36 WBTC; баланс USDG 0; `epoch = 1` |
| `test_ConvertFees_UsdgAsAsset_NoSwap` | Актив = USDG, свап не нужен. | — | Выход 100e6, alice `earned = 90e6` |

### Награды за стейкинг

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_Stake_AfterFees_EarnsNothingFromPriorFees` | Bob стейкает после прихода комиссии в той же эпохе. | Нет наград за комиссии до стейка (анти-сниппинг) | alice 108 AAPL, bob 0 |
| `test_Earned_TwoStakers_ProRata` | Два стейкера 3:1. | Награды пропорциональны стейку | alice 81 AAPL, bob 27 AAPL |
| `test_Earned_StakeChangesWithinEpoch_UsesEpochRate` | Стейк/анстейк между комиссиями внутри одной эпохи. | Каждая комиссия делится по стейкам на момент её прихода | alice 135e6, bob 135e6, создатель 30e6 |
| `test_Earned_SeveralEpochs_Accumulates` | Три эпохи подряд с одним стейкером. | Награды накапливаются между эпохами | alice 3×108 AAPL и 3×36 WBTC |
| `test_Earned_BeforeConversion_OnlyPendingCredit` | `earned` до конвертации. | Награды в активах только после конвертации | `earned = 0`, `pendingCreditOf(alice) = 90e6` |
| `test_NotifyFees_AllUnstaked_GoesToCreator` | Все вышли из стейка до прихода комиссии. | Без стейкеров всё идёт создателю | Создатель 100e6, alice 0 |

### Выплаты

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_Claim_AfterConversion_TransfersRewards` | Клейм всех активов после конвертации. | Выплачено = начислено, затем обнуление | alice получает 108 AAPL и 36 WBTC, `earned = 0` |
| `test_Claim_SubsetOfAssets_LeavesOthers` | Клейм только WBTC. | Неклеймнутые активы сохраняются | alice: 36 WBTC, 0 AAPL; AAPL `earned` остаётся 108 |
| `test_Claim_UnknownAsset_Reverts` | Клейм актива, которого нет в хранилище. | — | Revert `AssetNotInVault(meme, usdg)` |
| `test_Exit_UnstakesAndClaims` | `exit` = анстейк + клейм. | — | alice получает 1 000 MEME и 108 AAPL, `totalStaked = 0` |
| `test_ClaimCreatorRewards_PaysCreator` | Клейм наград создателя (кто угодно вызывает, платится создателю). | Награды создателя уходят только создателю | creator: 120 AAPL, 40 WBTC |

### Анстейк / пауза

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_Unstake_MoreThanStaked_Reverts` | Анстейк больше застейканного. | Нельзя вывести больше своего стейка | Revert `InsufficientStake(1e18, 2e18)` |
| `test_Unstake_WhilePaused_Succeeds` | Анстейк на паузе. | Пауза не блокирует вывод стейка | alice получает 1e18 MEME |
| `test_Claim_WhilePaused_Reverts` | Клейм на паузе. | Пауза блокирует выплаты | Revert `EnforcedPause` |
| `test_NotifyFees_WhilePaused_Succeeds` | Приём комиссии на паузе. | Пауза не ломает свопы (хук) | `pendingUSDG = 100e6` |

### Роль создателя / админ

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_TransferCreator_TwoStep_MovesRewards` | Двухшаговая передача роли создателя. | Роль меняется только после accept; награды идут новому создателю | До accept — старый creator; после — newCreator получает 120 AAPL |
| `test_TransferCreator_NotCreator_Reverts` | Передача роли не создателем. | Доступ только создателю | Revert `NotCreator` |
| `test_AcceptCreator_NotPending_Reverts` | Accept не от ожидающего адреса. | Принять может только pending-создатель | Revert `NotPendingCreator` |
| `test_RescueERC20_OnlySurplus` | Rescue случайно присланного MEME при наличии стейков. | Rescue не трогает учтённые средства | 6e18 → revert `RescueExceedsSurplus(meme, 5e18, 6e18)`; 5e18 → успешно выводится owner |
| `test_Setters_NotOwner_Reverts` | `setHook` не владельцем. | Доступ только владельцу | Revert `OwnableUnauthorizedAccount(alice)` |

### Перечисление allowlist

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_AllowedAssets_AfterSetup_ListsEveryAllowedAsset` | `allowedAssets()` после настройки фикстуры | Список = все разрешённые активы | 3 адреса: AAPL, WBTC, USDG |
| `test_SetAssetAllowed_Remove_DropsFromList` | Удаление WBTC из allowlist | Удалённый актив пропадает из списка и mapping | 2 адреса, WBTC нет, `isAssetAllowed(wbtc)` = false |
| `test_SetAssetAllowed_AddTwice_NoDuplicate` | Повторное добавление AAPL | Актив в списке не дублируется | Длина списка по-прежнему 3 |
| `test_SetAssetAllowed_RemoveNotListed_NoOp` | Удаление актива, которого нет в списке | Удаление отсутствующего ничего не ломает | Длина 3, `isAssetAllowed(meme)` = false |
| `test_SetAssetAllowed_NotOwner_Reverts` | `setAssetAllowed` не владельцем | Allowlist меняет только владелец | Revert `OwnableUnauthorizedAccount(alice)` |
| `testFuzz_SetAssetAllowed_ListMatchesMapping` (fuzz) | Случайная последовательность до 40 добавлений и удалений 4 активов | Список ровно совпадает с mapping, без дублей | Актив в списке ⇔ `isAssetAllowed` = true; длина = числу разрешённых |

### Фаззинг

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `testFuzz_Earned_TwoStakers_NeverExceedsConverted` (fuzz) | Случайные стейки и две комиссии, bob входит между ними; затем все клеймят. | Сумма наград ≤ сконвертированного; доля пропорциональна; нет наград до стейка; баланс = учтённое | `a+b+c ≤ out` (пыль ≤ 4 wei); bob ≈ доле fee2 (±2); после клеймов `accounted` = только пыль = баланс USDG |
| `testFuzz_ConvertFees_WeightsSumToInput` (fuzz) | Случайный вес USDG/AAPL при конвертации. | Сумма ног = входу, без потерь | USDG-нога = `fee·w/10000`, AAPL = остаток × курс; на балансе остаётся только USDG-нога |

### Автоматическая конвертация

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_SetConversionThreshold_NotOwner_Reverts` | Установка порога не владельцем. | Доступ только владельцу | Revert `OwnableUnauthorizedAccount(alice)` |
| `test_SetConversionThreshold_Owner_SetsAndEmits` | Установка порога владельцем. | — | Событие `ConversionThresholdUpdated(100e6)`, порог 100e6 |
| `test_ConvertFees_AnyCaller_Succeeds` | Ручная конвертация любым адресом. | Конвертация permissionless | `epoch = 1` |
| `test_ConvertFees_BelowThreshold_Reverts` | Ручная конвертация ниже порога. | Эпоха не закрывается ниже порога | Revert `BelowConversionThreshold(99e6, 100e6)` |
| `test_ConvertFees_AdapterReverts_Bubbles` | Адаптер ревертит при ручной конвертации. | — | Revert с `"adapter: revert"` |
| `test_ConvertFees_ZeroOutput_Reverts` | Свап вернул 0. | Нет конвертации в ноль | Revert `ZeroSwapOutput(aapl)` |
| `test_NotifyFees_BelowThreshold_KeepsEpochOpen` | 60 USDG при пороге 100. | Ниже порога эпоха открыта | `epoch = 0`, `pendingUSDG = 60e6`, баланс 60e6 |
| `test_NotifyFees_ReachesThreshold_ConvertsInSameTx` | 60+40 USDG достигают порога. | Достижение порога закрывает эпоху в той же транзакции | `epoch = 1`, pending 0, alice 108 AAPL / 36 WBTC, создатель 12 AAPL / 4 WBTC |
| `test_NotifyFees_AboveThreshold_ConvertsWholePending` | 1 000 USDG сразу выше порога, стейкеров нет. | Конвертируется весь pending | `epoch = 1`, pending 0, создатель 1 200 AAPL |
| `test_NotifyFees_ThresholdZero_NeverConvertsAutomatically` | Порог 0. | 0 = автоконвертация выключена | `epoch = 0`, `pendingUSDG = 1 000e6` |
| `test_NotifyFees_Paused_SkipsConversion` | Порог достигнут на паузе. | Пауза пропускает автоконвертацию без фиксации сбоя | `epoch = 0`, pending 100e6, `lastConversionFailure = 0`; после снятия паузы ручная конвертация → `epoch = 1` |
| `test_ConversionGasRequired_ThresholdOff_ReturnsZero` | Порог 0 | Без порога автоконвертации нет, газ не нужен | 0 |
| `test_ConversionGasRequired_BelowThreshold_ReturnsBudget` | Накоплено 40 при пороге 100, активы AAPL/WBTC | Газ нужен и до порога: оценка не устаревает, пока чужие сделки набирают порог | `CONVERSION_BASE_GAS + 2 × CONVERSION_GAS_PER_SWAP` |
| `test_ConversionGasRequired_UsdgAsset_NoSwapCounted` | Единственный актив USDG | USDG не меняется через адаптер | `CONVERSION_BASE_GAS` |
| `test_ConversionGasRequired_PausedOrCoolingDown_StillBudget` | Кулдаун после неудачной конвертации, затем пауза | Пауза и кулдаун не снижают требование: они могут закончиться между оценкой и сделкой | Полный бюджет в обоих случаях |
| `test_ConversionGasRequired_UnknownMeme_ReturnsZero` | Незарегистрированный мем | Неизвестный мем не требует газа | 0 |
| `testFuzz_ConversionGasRequired_StaticAndCoversEveryConversion` (fuzz) | Любые порог, накопленное и входящая сумма | Требование не зависит от накопленного; каждая конвертация была покрыта газом | Значение до и после зачисления одинаковое; эпоха закрылась ⇒ требование > 0 |
| `test_NotifyFees_ConversionReverts_KeepsCreditAndStartsCooldown` | Автоконвертация падает внутри `notifyFees`. | Сбой свапа не ломает хук и не теряет кредит | Событие `ConversionFailed`; `epoch = 0`; 90e6/10e6 сохранены; `lastConversionFailure = now`; `accounted = баланс = 100e6`; кредит alice 90e6 |
| `test_NotifyFees_WithinCooldown_DoesNotRetry` | Повтор автоконвертации в период cooldown и после. | Нет повторов во время cooldown | За 1 с до конца: `epoch = 0`, pending 101e6; после: `epoch = 1`, pending 0 |
| `test_NotifyFees_ConversionRevertsWithoutData_NoCooldown` | Revert без данных (как out-of-gas). | Пустой revert не включает cooldown | `ConversionFailed(meme, "")`, `lastConversionFailure = 0`; следующий notify → `epoch = 1` |
| `test_ConvertFees_Manual_IgnoresCooldown` | Ручная конвертация во время cooldown. | Cooldown влияет только на автоконвертацию | `epoch = 1` |
| `test_NotifyFees_FailedThenFixed_ConvertsAccumulatedEpochAtOnce` | Сбой, накопление, починка, автоконвертация после cooldown. | Накопленная эпоха конвертируется целиком | `epoch = 1`, alice 324 AAPL (90% от 360) |
| `testFuzz_NotifyFees_AutoConversion_ClosesEpochExactlyAtThreshold` (fuzz) | Случайный порог и 8 комиссий. | pending < порога после каждого notify; эпоха закрывается ровно при пересечении; баланс ≥ учтённого | `pendingUSDG < threshold`, `epoch` = числу пересечений, баланс ≥ `accounted` для USDG/AAPL/WBTC |

### Инварианты (VaultInvariantTest, handler: stake/unstake/notify/convert/claim/claimCreator/setProtocolShare, актив — только USDG, порог 5e14, доля протокола от 3333 и меняется handler'ом, получатель — EOA)

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `invariant_Pending_StaysBelowThreshold` | pending после любой последовательности действий. | pending всегда < порога | `pendingUSDG < 5e14` |
| `invariant_TotalStaked_EqualsSumOfStakes` | Сумма стейков акторов. | `totalStaked` = Σ стейков | Равенство |
| `invariant_CreatorShare_Immutable` | Доля создателя после любой последовательности действий. | `creatorShareBps` не меняется после регистрации | `creatorShareBpsOf(meme)` = 1000 |
| `invariant_Balances_CoverAccounted` | Балансы хранилища против учёта. | Баланс ≥ учтённого; баланс MEME = `totalStaked` | `usdg ≥ accounted`, `meme ≥ accounted`, `meme == totalStaked` |
| `invariant_Claimable_NeverExceedsNotified` | pending + выплаченное + начисленное (стейкеры + создатель). | Сумма наград ≤ пришедшей комиссии за вычетом доли протокола | ≤ `ghostNotified` |
| `invariant_Accounted_CoversClaimable` | Все обязательства против учтённого USDG. | Учтённое покрывает все долги | pending + earned + creatorAccrued ≤ `accounted(usdg)` || `invariant_ProtocolRecipient_GetsExactShareOfEveryNotify` | Баланс получателя протокола. | Протокол получает ровно floor(amount × share / BPS) каждой выплаты при текущей доле, ни единицы из части мема | баланс получателя = `ghostProtocol` |
| `invariant_ProtocolShare_NeverAboveBps` | Доля после любых `setProtocolShare`. | Доля ≤ BPS | `protocolShareBps ≤ 10000` |

## test/VaultUpgradeTest.sol

Деплой через `GemoonDeploy` (прокси + ProxyAdmin), апгрейд через скрипт; `VaultV2` — реализация с версией 2.

### Деплой / инициализация

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_DeployVault_Configured_ProxyWithRolesAndOwner` | Конфигурация после деплоя скриптом. | Прокси корректно инициализирован, роли выставлены | owner, usdg, controller, hook, adapter заданы; порог 0; активы разрешены; ProxyAdmin у upgradeScript; версия инициализации 1; реализация ≠ 0 |
| `test_DeployVault_OwnerDiffers_OwnershipPending` | Деплой, где владелец ≠ деплоер. | Ownable2Step: владение передаётся через accept | `owner = deployScript`, `pendingOwner = owner`, controller 0, порог 5e6 |
| `test_Initialize_Twice_Reverts` | Повторный `initialize` на прокси. | Однократная инициализация | Revert `InvalidInitialization` |
| `test_Initialize_Implementation_Reverts` | `initialize` на самой реализации. | Реализация заблокирована | Revert `InvalidInitialization` |
| `test_Initialize_ZeroUsdg_Reverts` | Инициализация с нулевым USDG. | — | Revert `ZeroAddress` |
| `test_Reinitialize_SameVersion_Reverts` | `reinitialize` до текущей `VAULT_VERSION` и повторно. | Реинициализация один раз на версию | Первый вызов поднимает версию до `VAULT_VERSION`, второй — revert `InvalidInitialization` |

### Апгрейд

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_UpgradeVault_SameVersion_SwapsImplementation` | Апгрейд до текущей версии, затем ещё раз на реализацию той же версии. | Состояние сохраняется, повторный апгрейд не реинициализирует | Реализация заменена, версия = `VAULT_VERSION`, owner сохранён |
| `test_UpgradeVault_VersionBump_RunsReinitialize` | Апгрейд на мок следующей версии (`VAULT_VERSION + 1`). | Реинициализация выполняется один раз | Версия `VAULT_VERSION + 1`, owner/usdg сохранены; повторный `reinitialize` — revert |
| `test_UpgradeVault_Downgrade_Reverts` | Откат с `VAULT_VERSION + 1` на текущую. | Запрет даунгрейда | Revert `VersionDowngrade(VAULT_VERSION + 1, VAULT_VERSION)` |
| `test_UpgradeVault_NotProxyAdminOwner_Reverts` | Апгрейд от имени не владельца ProxyAdmin. | Апгрейд только владельцем ProxyAdmin | Revert `NotProxyAdminOwner(upgradeScript, alice)` |
| `test_UpgradeVault_WrongProxyAdmin_Reverts` | Передан чужой адрес ProxyAdmin. | — | Revert `ProxyAdminMismatch(alice, proxyAdmin)` |
| `test_UpgradeAndCall_NotAdminOwner_Reverts` | Прямой `upgradeAndCall` от owner хранилища. | Owner хранилища ≠ право апгрейда | Revert `OwnableUnauthorizedAccount(owner)` |
| `test_UpgradeVault_WithStakesAndRewards_KeepsAccountingAndClaims` | Апгрейд при стейках, наградах и открытой эпохе. | Апгрейд не меняет учёт | earned и кредит alice без изменений; `totalStaked = 400e18`; pending 500e6; клейм выплачивает ровно прежний earned |

### Фаззинг

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `testFuzz_UpgradeVault_PreservesState` (fuzz) | Случайные стейки и комиссии, затем апгрейд на V2. | Апгрейд не меняет наблюдаемый учёт | earned (alice, bob), creatorAccrued, `accounted` (USDG/AAPL/MEME), стейки и owner совпадают до и после |

## test/UniswapV3SwapAdapterTest.sol

### Конструктор и администрирование

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_Constructor_ZeroAddress_Reverts` | Деплой с нулевым factory, vault или USDG. | Ключевые адреса адаптера не нулевые | Каждый вариант откатывается с `ZeroAddress` |
| `test_Constructor_WindowOutOfBounds_Reverts` | Деплой с окном TWAP 59 с и 3601 с. | Окно TWAP в пределах [60, 3600] с | Откат `InvalidTwapWindow(59)` и `InvalidTwapWindow(3601)` |
| `test_Constructor_SetsOwnerDirectly` | Начальное состояние после деплоя. | Владелец назначается сразу, без pending | `owner == owner`, `pendingOwner == 0`, `i_vault`, `i_usdg`, `twapWindow == 600` заданы |
| `test_SetRoute_NotOwner_Reverts` | `setRoute` от постороннего адреса. | Маршруты меняет только владелец | Откат `OwnableUnauthorizedAccount(alice)` |
| `test_SetRoute_PoolNotFound_Reverts` | `setRoute` с тиром комиссии 500, для которого нет пула. | Маршрут указывает только на существующий пул | Откат `PoolNotFound(assetHigh, 500)` |
| `test_SetRoute_SlippageAboveCap_Reverts` | `setRoute` с допуском `MAX_SLIPPAGE_BPS + 1` (1001 bps). | Допуск проскальзывания не выше 10% | Откат `SlippageTooHigh(1001)` |
| `test_SetRoute_Usdg_Reverts` | Маршрут для самого USDG. | Нельзя менять USDG на USDG | Откат `InvalidAsset(usdg)` |
| `test_SetRoute_PoolCannotServeWindow_Reverts` | Пул не отдаёт историю на окно TWAP (`observe` падает). | Маршрут только для пула с оракулом на всё окно | Откат с причиной пула `"OLD"` |
| `test_SetRoute_StoresAndEmits` | Успешный `setRoute` с допуском 250 bps. | — | Событие `RouteSet(assetHigh, poolHigh, 3000, 250)`; `routeOf` возвращает pool, fee, 250 |
| `test_RemoveRoute_SwapRevertsAfterwards` | Удаление маршрута и последующий swap. | Без маршрута обмен невозможен | `routeOf.pool == 0`; swap откатывается с `RouteNotSet(assetHigh)` |
| `test_SetTwapWindow_OutOfBounds_Reverts` | `setTwapWindow(0)`, затем допустимое 3600. | Окно TWAP в пределах [60, 3600] с | 0 откатывается с `InvalidTwapWindow(0)`; 3600 принимается, `twapWindow == 3600` |
| `test_Sweep_SendsWholeBalance` | Владелец выводит застрявший USDG. | — | Alice получает 7e6, баланс адаптера 0 |

### Защита swap

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_Swap_NotVault_Reverts` | Вызов `swap` не из vault. | Обмен вызывает только vault | Откат `NotVault` |
| `test_Swap_WrongTokenIn_Reverts` | Входной токен не USDG. | Адаптер продаёт только USDG | Откат `UnexpectedTokenIn(assetLow)` |
| `test_Swap_ZeroAmount_Reverts` | `swap` с нулевой суммой. | — | Откат `ZeroAmount` |
| `test_Swap_ObserveReverts_Bubbles` | Оракул пула недоступен во время swap. | Без TWAP обмен не выполняется | Откат с причиной пула `"OLD"` |
| `test_Callback_NotRoutePool_Reverts` | `uniswapV3SwapCallback` от постороннего и от пула другого актива. | Callback платит только пулу маршрута данного актива | Откат `NotPool(alice)` и `NotPool(poolLow)` |

### Цена обмена

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_Swap_SpotEqualsTwap_PaysSpotQuote_BothDirections` | Обмен при spot == TWAP в обоих направлениях (USDG как token0 и token1). | Выход не ниже TWAP минус допуск; весь вход уходит в пул | Выход равен котировке на тике 0, получен alice, `>= minAmountOut`; у адаптера 0 USDG, у каждого пула AMOUNT |
| `test_Quote_NetOfPoolFee` | `quote` и `minAmountOut` на тике 0. | Котировка учитывает комиссию пула, нижняя граница = котировка минус допуск | `quote = AMOUNT*(1e6-3000)/1e6`; `minAmountOut` = это значение × 99% |
| `test_Swap_SpotWithinTolerance_Succeeds` | Spot хуже TWAP на ~0,5% (50 тиков) в обоих направлениях. | Выход не ниже TWAP минус допуск | Обмен проходит, выход `>= minAmountOut` |
| `test_Swap_SpotBeyondTolerance_Reverts` | Spot хуже TWAP на ~2% (200 тиков) в обоих направлениях. | Обмен по манипулированной цене отклоняется | Оба swap откатываются с `InsufficientOutput` |
| `test_Swap_PartialFill_Reverts` | Пул исполняет только 99,9% входа. | Вход тратится полностью, без остатка в адаптере | Откат `PartialFill(assetHigh, AMOUNT, AMOUNT*9990/10000)` |
| `test_Swap_SpotBetterThanTwap_Succeeds` | Spot лучше TWAP на ~5%. | Лучшая цена не ограничивается сверху | Обмен проходит, выход `> AMOUNT` |
| `testFuzz_Swap_SpotEqualsTwap_ClearsBound` (fuzz) | Любой тик в [-300000, 300000] и сумма до uint96 при spot == TWAP, оба направления. | Spot == TWAP всегда проходит границу; весь вход уходит в пул | Оба выхода `>= minAmountOut`, у адаптера 0 USDG |
| `testFuzz_Swap_AcceptsIffSpotMeetsBound` (fuzz) | Сдвиг spot на ±2000 тиков от TWAP, сумма от 1e6. | Обмен проходит тогда и только тогда, когда spot-выход `>= minAmountOut` | При `spotOut >= minOut` возвращается `spotOut`; иначе откат `InsufficientOutput(assetHigh, spotOut, minOut)` |

### Интеграция с Vault

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_Vault_ConvertFees_ThroughAdapter_BooksAssets` | Реальный Vault за прокси конвертирует комиссии через адаптер при достижении порога, затем при сломанном оракуле. | Сбой конвертации не теряет начисленные комиссии | 1-й вызов: epoch 1, USDG 0, у vault 60e6 assetHigh и 40e6 assetLow, всё начислено создателю. 2-й (оракул падает): epoch остаётся 1, `pendingUSDG == 100e6`, `lastConversionFailure == block.timestamp` |

## test/DeployGemoonTest.sol

### Скрипт деплоя

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_DeployAll_Wiring_AllContractsPointAtEachOther` | Взаимные ссылки controller, hook и vault после `deployAll`. | Контракты связаны друг с другом и с одним USDG | Все ссылки совпадают, `checkWiring` не откатывается |
| `test_DeployAll_Config_AppliedFromParams` | Применение параметров деплоя. | — | Порог 5e6; AAPL разрешён, USDG нет; `vault.protocolRecipient`, fee 125, `vault.protocolShareBps` 2000 (20% комиссии), poolManager, positionManager, permit2 заданы |
| `test_DeployAll_Ownership_HandedToOwner` | Передача владения и прав ProxyAdmin. | Владение у заданного owner; апгрейды у proxyAdminOwner | Hook и controller принадлежат owner; vault ждёт `acceptOwnership` (pending = owner), после принятия owner = owner; ProxyAdmin vault и controller у proxyAdminOwner |
| `test_DeployAll_OwnerIsDeployer_NoTransfer` | Owner совпадает с деплоером. | — | Все контракты принадлежат скрипту, pending у vault = 0 |
| `test_DeployAll_HookAddress_CarriesPermissionBits` | Биты разрешений в адресе hook. | Адрес hook несёт ровно нужные флаги Uniswap v4 | `addr & ALL_HOOK_MASK == HOOK_FLAGS` |
| `test_DeployAll_Hook_NotAProxy` | Hook задеплоен без прокси. | Hook не обновляемый: ни код, ни комиссии не меняются под живым пулом | EIP-1967 implementation и admin = 0; `TOTAL_FEE_BIPS` = 125 из конструктора |
| `test_DeployAll_Twice_FreshAddresses` | Повторный деплой. | Повторный деплой не сталкивается по CREATE2 | Новый адрес hook; второй деплой корректно связан |
| `test_Run_FromEnv_DeploysAndWires` | `run()` с конфигом из переменных окружения, часть пустая. | Пустые env берут значения по умолчанию | Связи корректны; владелец owner, vault pending = owner; ProxyAdmin = owner (fallback); fee 300, доля протокола по умолчанию 3333 (треть); AAPL разрешён; порог 5e6; биты hook верны |
| `test_SetVault_UsdgMismatch_Revert` | Подключение к контроллеру vault с другим USDG. | Пара-токен контроллера и USDG vault совпадают | Откат `VaultPairTokenMismatch(aapl, usdg)` |
| `test_CheckWiring_VaultOfOtherHook_Revert` | `checkWiring` с hook из другого деплоя. | Проверка связей ловит чужой hook | Откат `WiringMismatch("controller.hook")` |

### HookManager: контроллер

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_AfterInitialize_FirstPool_RecordsBlockTimestamp` | Хук сам записывает время при `initialize` первого пула мема контроллером. | Начало окна задаёт хук, не роль | Событие `PoolTimestampRecorded(meme, 1_700_000_000)`, `poolTimestamps(meme) == 1_700_000_000`, комиссия 80% |
| `testFuzz_AfterInitialize_LaterPool_KeepsFirstTimestamp` (fuzz) | Любой может создать ещё один пул мема (другой tick spacing) в любой момент. | Новый пул не перезапускает окно живого мема | `poolTimestamps` прежний; после окна комиссия = базовая 300 |
| `testFuzz_AfterInitialize_NotController_DoesNotStartWindow` (fuzz) | Пул мема без окна (старый мем) инициализирует кто угодно, кроме контроллера. | Сторонний пул не включает 80% на живом меме | `poolTimestamps == 0`, комиссия 125; `notifyPoolCreated` → `PoolNotCreatedInThisBlock(meme, 0)` |
| `test_AfterInitialize_NotPoolManager_Revert` | Прямой вызов `afterInitialize` не от PoolManager. | Записать время можно только через реальный `initialize` | Откат `NotPoolManager` |
| `test_NotifyPoolCreated_SameBlockAsPool_StoresFee` | Контроллер задаёт ставку в блоке создания пула. | — | Событие `MemeFeeConfigured(meme, 100, createdAt)`, `memeFeeBips == 100` |
| `testFuzz_NotifyPoolCreated_FromController_StoresPerMeme` (fuzz) | Пул и ставка для случайного meme в любой момент. | Запись изолирована по meme | `poolTimestamps(meme) == timestamp`, `memeFeeBips == 100`, у другого meme 0 |
| `test_NotifyPoolCreated_CalledTwice_RevertsPoolAlreadyNotified` | Второй вызов для того же meme с другой ставкой. | Ставка задаётся один раз на мем | Откат `PoolAlreadyNotified(meme)`, время 100 и ставка 100 прежние |
| `test_NotifyPoolCreated_NoPool_RevertsPoolNotCreatedInThisBlock` | Вызов для мема без пула. | Без пула окно 80% не включить | Откат `PoolNotCreatedInThisBlock(meme, 0)`, комиссия = 125 |
| `testFuzz_NotifyPoolCreated_LivePool_Reverts` (fuzz) | Сценарий аудита: пул торгуется, контроллер через ≥1 с пытается сообщить о нём с любой ставкой. | Контроллер не может включить 80% на живом пуле | Откат `PoolNotCreatedInThisBlock(meme, 1000)`, окно и ставка не изменились, после окна комиссия = 125 |
| `test_NotifyPoolCreated_OwnerAsController_CannotRestartRamp` | Владелец делает себя контроллером, пытается сменить ставку и создаёт второй пул после окна. | Даже владелец хука не поднимет комиссию живого мема | `PoolAlreadyNotified`, комиссия остаётся базовой 100 |
| `testFuzz_NotifyPoolCreated_AfterFirst_AnyReport_RampUnchanged` (fuzz) | Повторный вызов в любой момент с любой ставкой. | После первого сообщения время и ставка мема неизменны; через 30 с комиссия базовая | Откат `PoolAlreadyNotified`, `poolTimestamps`/`memeFeeBips` прежние |
| `test_NotifyPoolCreated_FromOwner_Revert` | Вызов от владельца hook. | Уведомлять может только контроллер | Откат `NotController` |
| `test_NotifyPoolCreated_FromVault_Revert` | Вызов от vault. | Уведомлять может только контроллер | Откат `NotController` |
| `test_NotifyPoolCreated_FromNewController_AfterSetController_Stores` | Новый контроллер после `setController`, в блоке создания пула. | Права переходят к новому контроллеру | `memeFeeBips(meme) == 100` |
| `testFuzz_NotifyPoolCreated_NotController_Revert` (fuzz) | Вызов от любого адреса, кроме контроллера. | Уведомлять может только контроллер | Откат `NotController`, ставка остаётся 0 |
| `test_SetController_ByOwner_UpdatesAndEmits` | Владелец меняет контроллер. | Старый контроллер сразу теряет доступ | Событие `ControllerUpdated(next)`, `controller == next`; старый получает откат `NotController` |
| `test_SetController_NotOwner_Revert` | `setController` от постороннего. | Контроллер меняет только владелец | Откат `OwnableUnauthorizedAccount(stranger)` |
| `test_SetController_ZeroAddress_Revert` | `setController(0)`. | Контроллер не нулевой | Откат `ZeroAddress` |

## test/HookFeeMath.sol

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_Constants_MaxFee80Percent_MemeFeeBounds1To5Percent` | Значения констант хука | Потолок комиссии 80%, комиссия мема в пределах 1–5% | `MAX_FEE_BIPS`=8000, `MIN_MEME_FEE_BIPS`=100, `MAX_MEME_FEE_BIPS`=500, окно `DYNAMIC_FEE_THRESHOLD` > 1 с |
| `test_FeeBipsAt_AtCreation_ReturnsMax` | Комиссия в момент создания пула | Старт кривой — максимум | `feeBipsAt(meme, createdAt)` = 8000 |
| `test_FeeBipsAt_BeforeCreation_ReturnsMax` | Комиссия для времени раньше создания пула | Комиссия до создания не ниже максимума | `feeBipsAt(createdAt-1)` = 8000 |
| `test_FeeBipsAt_OneSecond_BelowMax` | Комиссия через 1 с после создания | Спад начинается сразу | Равна линейной формуле `_expected(1)`, < 8000 |
| `test_FeeBipsAt_HalfWindow_ReturnsMidpoint` | Комиссия в середине окна | Линейность кривой | `_expected(window/2)`; при чётном окне = 4250 (между 80% и 5%) |
| `test_FeeBipsAt_LastSecond_AboveMemeFee` | Комиссия за 1 с до конца окна | Внутри окна комиссия строго выше комиссии мема | `_expected(window-1)`, > 500 |
| `test_FeeBipsAt_WindowEnd_ReturnsMemeFee` | Комиссия ровно в конце окна | После окна — комиссия, выбранная создателем | 500 |
| `test_FeeBipsAt_LongAfter_ReturnsMemeFee` | Комиссия через 365 дней | Комиссия не уходит ниже комиссии мема | 500 |
| `test_FeeBipsAt_UnknownPool_ReturnsFallbackFee` | Комиссия для незарегистрированного мема | Неизвестный пул получает дефолтную комиссию | `feeBipsAt` и `baseFeeBips` = 125 |
| `test_CurrentFeeBips_FollowsBlockTimestamp` | `currentFeeBips` при разных `block.timestamp` | `currentFeeBips` = `feeBipsAt(block.timestamp)` | 8000 → `_expected(window/2)` → 500 |
| `testFuzz_FeeBipsAt_AlwaysBetweenMemeFeeAndMax` (fuzz) | Комиссия для любого timestamp | Комиссия всегда в [memeFee, 80%] | 500 ≤ fee ≤ 8000 |
| `testFuzz_FeeBipsAt_NeverIncreasesOverTime` (fuzz) | Сравнение комиссии в t1 ≤ t2 | Комиссия монотонно не растёт со временем | `fee(t1)` ≥ `fee(t2)` |
| `testFuzz_FeeBipsAt_InsideWindow_MatchesLinearFormula` (fuzz) | Комиссия для любого момента внутри окна | Кривая точно линейна: `MAX - (MAX-meme)*elapsed/window` | Совпадает с `_expected(elapsed)` |
| `test_NotifyPoolCreated_StoresMemeFeeAndEmits` | Пул создан, контроллер в том же блоке задаёт комиссию 3% | Комиссия создателя сохраняется и логируется | Событие `MemeFeeConfigured(other, 300, createdAt)`; `memeFeeBips`=`baseFeeBips`=300 |
| `test_NotifyPoolCreated_FeeBelowOnePercent_Revert` | Регистрация с комиссией 0,99% | Комиссия мема ≥ 1% | Revert `InvalidMemeFeeBips(99)` |
| `test_NotifyPoolCreated_FeeAboveFivePercent_Revert` | Регистрация с комиссией 5,01% | Комиссия мема ≤ 5% | Revert `InvalidMemeFeeBips(501)` |
| `testFuzz_NotifyPoolCreated_FeeInBounds_BecomesBaseFee` (fuzz) | Любая допустимая комиссия 100–500 | После окна действует ровно выбранная создателем комиссия | `feeBipsAt(createdAt+window)` = feeBips |
| `testFuzz_NotifyPoolCreated_FeeOutOfBounds_Revert` (fuzz) | Любая комиссия вне 100–500 | Нельзя задать комиссию вне границ | Revert `InvalidMemeFeeBips(feeBips)` |
| `test_Constructor_FallbackFeeAboveMax_Revert` | Резервная ставка 80.01% | Резервная ставка ≤ `MAX_FEE_BIPS` | Revert `InvalidFeeBips` |
| `testFuzz_Constructor_FallbackFeeUpToMax_Accepted` (fuzz) | Любая резервная ставка 0..80% | Допустимая ставка принимается как есть; доли протокола в хуке нет, разбивка в волте | `TOTAL_FEE_BIPS` = переданной ставке |

## test/TokenTest.sol

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_Creator_SetInConstructor_ReturnsCreator` | Создатель токена задаётся в конструкторе | — | `creator()` = `0xC0FFEE` |
| `testTokenGetAdmin` | Список админов после создания токена | Админы и флаг `removable` сохраняются как переданы | 2 админа: [msg.sender, false], [address(0), true] |
| `testTokenAddressIsAdmin` | `isAdmin` для админа из конфига | — | `isAdmin(msg.sender)` = true |
| `testTokenReplaceReplacableAdmin` | Админ заменяет удаляемого админа address(1) на address(2) | Админ может заменить только удаляемого админа | `getAdmins()[1].admin` = address(2) |
| `testTokenReplaceReplacableAdminWithoutAdminRole` | Не-админ пытается заменить админа | Только админ заменяет админов | revert `NotAdmin("Only admin can replace admin")` (строка) |
| `testTokenChangeDescription` | Админ меняет описание | — | `description()` = "New description" |
| `testTokenChangeDescriptionFailBecauseUserIsNotAdmin` | Не-админ меняет описание | Только админ меняет метаданные токена | Revert "Caller is not an admin" |
| `testGetTokenInfo` | Геттеры метаданных после конструктора | — | description, name "Test Token", symbol "TEST", 4 ссылки на соцсети совпадают с конфигом |

## test/TokenHoldersTest.sol

`totalHolders` = число адресов с ненулевым балансом. Вся эмиссия минтится деплоеру (тесту), он единственный холдер на старте.

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_TotalHolders_AfterMint_DeployerOnly` | После конструктора | Минт из address(0) не считает нулевой адрес | 1 |
| `test_TotalHolders_TransferToNew_Increments` | Перевод новому адресу | 0 → >0 добавляет холдера | 2 |
| `test_TotalHolders_TransferToExistingHolder_Unchanged` | Повторный перевод тому же | Уже холдер не считается дважды | 2 |
| `test_TotalHolders_WholeBalanceMoved_SenderLeaves` | Отправитель отдал всё | >0 → 0 убирает холдера | 2 (деплоер + bob) |
| `test_TotalHolders_ZeroValueTransfer_Unchanged` | Перевод 0 | Нулевой перевод не делает холдером | 1 |
| `test_TotalHolders_SelfTransfer_Unchanged` | Перевод самому себе | Баланс не меняется — счётчик тоже | 2 |
| `test_TotalHolders_BurnWholeBalance_Leaves` | Сжёг всё | Burn в address(0) убирает холдера, нулевой адрес не считается | 1 |
| `test_TotalHolders_BurnPart_Unchanged` | Сжёг часть | — | 2 |
| `test_TotalHolders_TransferFrom_CountsLikeTransfer` | `transferFrom` | Учёт тот же, что у `transfer` | 2 |
| `test_TotalHolders_EverythingBurned_Zero` | Сожжена вся эмиссия | Счётчик доходит до 0 без underflow | 0 |
| `testFuzz_TotalHolders_Transfer_MatchesBalances` (fuzz) | Два перевода любых сумм на любой адрес | Счётчик = число ненулевых балансов | совпадает |

### Инварианты (TokenHoldersInvariantTest, handler: transfer / transferFrom / burn / burnAll между 5 адресами, включая self и нулевые суммы)

| Тест | Инвариант |
|---|---|
| `invariant_TotalHoldersEqualsNonZeroBalances` | `totalHolders()` = число адресов с ненулевым балансом |

## test/TokenURITest.sol

ERC-1046 `tokenURI` токена: свой URI админа (`setTokenURI`), если задан, иначе `data:application/json;base64,` от JSON, собранного ончейн из name, symbol, decimals, description, image, ссылок на соцсети (стандартные ключи `twitter`/`telegram`/`website` на верхнем уровне, только заданные, плюс `socialMedia`) и распределения комиссии (`fees`). Каждый тест декодирует base64 и читает поля через `vm.parseJson`.

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_TokenURI_Prefix_DataJsonBase64` | Формат URI | `data:application/json;base64,` + OZ `Base64` от JSON | совпадает |
| `test_TokenURI_Fields_MatchTokenData` | Основные поля | JSON = данные токена | name, symbol, decimals 18, description, image |
| `test_TokenURI_SocialMedia_AllFourLinks` | Соцсети | Все 4 ссылки в `socialMedia` | farcaster, twitterX, telegram, website |
| `test_TokenURI_EmptySocialMedia_EmptyStrings` | Пустые соцсети | JSON валиден и без ссылок | пустые строки |
| `test_TokenURI_TopLevelLinks_StandardKeys` | Ссылки на верхнем уровне | Стандартные ключи для агрегаторов, farcaster только в `socialMedia` | `twitter`, `telegram`, `website` = ссылки; `farcaster` нет |
| `test_TokenURI_EmptySocialMedia_NoTopLevelLinks` | Без ссылок | Незаданная ссылка — нет ключа, JSON валиден | ключей `twitter`/`telegram`/`website` нет, JSON совпадает байт в байт |
| `test_TokenURI_OnlyTelegram_OnlyTelegramKey` | Задан только telegram | Ключ есть только у заданной ссылки | есть только `telegram` |
| `testFuzz_TokenURI_TopLevelLinks_PresentIffSet` (fuzz) | Любые ASCII-ссылки до 128 байт | Ключ есть ⇔ ссылка непустая, значение = ссылка = копия в `socialMedia`, инъекция полей невозможна | совпадает, `image` не задет |
| `test_TokenURI_Json_ExactLayout` | Точная раскладка JSON | Формат стабилен для фронта и агрегаторов | строка совпадает байт в байт, включая `twitter`/`telegram`/`website` и `fees` |
| `test_TokenURI_Fees_PercentOfSwap` | `fees` в JSON | Проценты от суммы свопа = ppm / 10 000 | 1.25, 0.0833, 0.7501, 0.4166 |
| `test_FeeInfo_Getter_ReturnsConstructorValue` | `feeInfo()` | Геттер отдаёт значение из конструктора | 12 500, 833, 7 501, 4 166 |
| `test_TokenURI_FeesFormatting_WholeAndLeadingZeros` | Целые проценты и нули в дробной части | Целое без точки, ведущие нули дроби сохраняются, хвостовые отброшены | `10`, `6.6664`, `0.0003`, `3.3333` |
| `test_Constructor_FeePartsNotSummingToTotal_Reverts` | Части не дают в сумме total | В токене не бывает несходящегося распределения | revert `InvalidFeeInfo` |
| `testFuzz_TokenURI_Fees_ExactPercent` (fuzz) | Любые части 0..100% | JSON валиден, каждый процент читается обратно в тот же ppm без потерь | совпадает |
| `test_TokenURI_AfterUpdateImageAndDescription_Reflected` | После смены метаданных админом | URI всегда отражает текущие данные | новые image и description |
| `test_TokenURI_QuoteInDescription_NoInjection` | Кавычки в описании | Создатель не может подменить поля JSON | description как есть, image прежний |
| `test_TokenURI_ControlCharsAndBackslash_RoundTrip` | `\`, `"`, `\n`, `\r`, `\t`, 0x01, 0x1f | Экранирование по RFC 8259 | строки возвращаются без изменений |
| `test_TokenURI_Utf8_KeptAsIs` | UTF-8 (кириллица, эмодзи) | Байты ≥ 0x20 не трогаются | строки без изменений |
| `test_Escape_Plain_ReturnsSameString`, `test_Escape_SpecialChars_Escaped` | `Json.escape` | Без спецсимволов — та же строка; спецсимволы — короткие escape или `\u00XX` | точные строки |
| `testFuzz_TokenURI_AsciiDescription_RoundTrip` (fuzz) | Любое ASCII-описание до 256 байт | JSON всегда валиден, описание возвращается как есть, остальные поля не задеты | совпадает |
| `test_SetTokenURI_Admin_OverridesOnChainJson` | Админ задаёт свой URI | Свой URI заменяет ончейн JSON, событие | `tokenURI()` = `ipfs://custom.json`, `UpdateTokenURI` |
| `test_SetTokenURI_Empty_BackToOnChainJson` | Сброс пустой строкой | Пустой URI возвращает ончейн JSON | URI равен исходному, JSON валиден |
| `test_SetTokenURI_NotAdmin_Reverts` | Не админ | URI меняет только админ | revert "Caller is not an admin", URI прежний |
| `test_SetTokenURI_CustomSet_IgnoresMetadataUpdates` | Свой URI + смена image/description | Свой URI отдаётся как есть | `ipfs://custom.json` |
| `testFuzz_SetTokenURI_AnyUri_ReturnedOrOnChain` (fuzz) | Любая строка | Непустая отдаётся как есть, пустая — ончейн JSON | совпадает |
| `test_SupportsInterface_ERC1046_True` | ERC-165 для ERC-1046 | id = `0x3c130d90`, виден через `ERC165Checker` | `true` |
| `test_SupportsInterface_ERC165AndERC20_True` | ERC-165 для базовых интерфейсов | — | `true` для IERC165, IERC20, IERC20Metadata |
| `test_SupportsInterface_InvalidId_False` | Неизвестные id | `0xffffffff` всегда `false` (ERC-165) | `false` для `0xffffffff` и ERC-721 |

## test/AdminTest.sol

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `testAdmin_setCorrectly` | Конструктор `Admin` с одним админом | — | `getAdmins().length` = 1 |
| `testAdmin_replaceSuccessfull` | Удаляемый админ 0x1 заменяет себя на 0x2 | — | `getAdmins()[0].admin` = 0x2 |
| `testAdmin_replaceFailBecauseAdminIsntRemovable` | Замена неудаляемого админа | Неудаляемого админа нельзя заменить | Revert (`"Admin is not removable!"`, проверяется только факт revert) |
| `testAdmin_replaceFailBecauseIsntFunctionCalledByAdmin` | Замена админа вызовом не от админа | Только админ заменяет админов | Revert (`NotAdmin`, проверяется только факт revert) |
| `testAdmin_checkAdminSuccess` | `isAdmin` для админа | — | true |
| `testAdmin_checkAdminFail` | `isAdmin` для чужого адреса | — | false |

## test/HashTest.sol

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `testHashTokenPair` | Хэш пары токенов в двух порядках | Хэш пары не зависит от порядка токенов | `hashTokenPair(A,B)` = `hashTokenPair(B,A)` |

## test/PercentTest.sol

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `testSubPercent` | Вычитание процента | — | 100−20% = 80; 100−0% = 100; 0−20% = 0; 1e18−50% = 5e17 |
| `testAddPercent` | Прибавление процента | — | 100+20% = 120; 100+0% = 100; 0+20% = 0 |

## test/PriceMathTest.sol

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `testRoundPriceMath` | Округление тика к шагу 60 | — | −138162 → −138180; 138162 → 138180 |
| `testTick` | sqrtPrice для 1e24:1e18 → тик → округление | — | tick = −138163, округлённый = −138180 |
| `testGetSqrtPriceX96` | sqrtPriceX96 для 3333333e18:1e18 | — | 43395053968500547563162768 |
| `test_GetSqrtPriceX96_SixDecimalPairAsToken1_KeepsPrecision` | Цена 300_000 мемов (18 dec) за 1 USDG (6 dec), мем token0 | Точность не теряется на малых отношениях | Цена ≈ 3.333e18 (×1e-36), отклонение ≤ 1e-6 |
| `test_GetSqrtPriceX96_SixDecimalPairAsToken0_KeepsPrecision` | То же, но USDG token0 | Точность сохраняется в обратном порядке | Цена ≈ 3e53 (×1e-36), отклонение ≤ 1e-6 |
| `testFuzz_GetSqrtPriceX96_RoundTrip` (fuzz) | Количества 1e6–1e30 → sqrtPrice → цена | Обратное преобразование даёт исходное отношение | Цена ≈ `token1*1e36/token0`, отклонение ≤ 1e-9 |
| `test_GetSqrtPriceX96_StartPrice_SameForEitherTokenOrder` | Пример цены 300 000 мемов за 1 пару при мем token0 и token1 (не константа протокола) | Смена порядка токенов даёт обратную цену (sqrtA·sqrtB = 2^192) | sqrt = 144650172662492649647717392874717 и 43395051798747794894315217; цены ≈ 3.33e45 и 3e29; произведение ≈ 2^192 |
| `testFuzz_GetSqrtPriceX96_StartPrice_AnyDecimals_InverseAndInRange` (fuzz) | Стартовая цена протокола `PRICE_PER_TOKEN` для decimals 6–18 у мема и пары | Цена в диапазоне тиков Uniswap в обоих порядках, порядки взаимно обратны | `MIN_SQRT_PRICE` ≤ sqrt < `MAX_SQRT_PRICE` для обоих; произведение ≈ 2^192 (≤ 1e-9) |

## test/TimeMath.sol

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `testGetTimeElapsed` | Прошедшее время за 100 с | — | 100 |
| `testGetTimeElapsed_one_minute` | Прошедшее время за 60 с | — | 60 |
| `testGetPercentageTimeElapsed` | Доля прошедшего времени от 1 минуты (в bips) | — | 0 с → 0; 20 с → 3333; 50 с → 8333; 60 с → 10000 |

## test/TestProxy.sol

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `testControllerOwner` | Владелец `GemoonController` за `TransparentUpgradeableProxy` после `initialize` | Владелец задаётся при инициализации прокси | `owner()` = msg.sender |
| `testControllerProxyChangeAdmin` | Владелец передаёт владение через прокси | Только владелец передаёт владение | `owner()` = 0x1234 |

## test/TransferToGovernanceTest.sol

Передача владения: ProxyAdmin, контроллер и хук под `TimelockController`, которым управляет Safe; волт (и рефералы, адаптер) — Safe. Деплой настоящий (`DeployGemoon.deployAll`), владелец всего — скрипт, как деплоер в сети.

| Тест | Что проверяет | Инварианты | Ожидаемый результат |
|---|---|---|---|
| `test_DeployTimelock_SafeOnlyRoles_NoAdmin` | Роли нового таймлока | Предлагать, исполнять и отменять может только Safe; админа нет | задержка 48 ч, роли у Safe, `DEFAULT_ADMIN_ROLE` ни у кого |
| `test_TransferToGovernance_Owners_TimelockAndSafe` | Владельцы после передачи | Апгрейды и торговые настройки — за таймлоком, операционные — у Safe | ProxyAdmin ×3 и контроллер — таймлок, хук — pending таймлок, волт — pending Safe |
| `test_TransferToGovernance_Deployer_CannotUpgrade` | Деплоер после передачи | У деплоера нет права на апгрейд | `upgradeAndCall` от деплоера — `OwnableUnauthorizedAccount` |
| `test_TransferToGovernance_HookAccept_OnlyAfterDelay` | Принятие хука через таймлок | Ничего не исполняется раньше задержки | `execute` до 48 ч откатывается, после — владелец хука таймлок |
| `test_TransferToGovernance_SafeAcceptsVault` | Safe принимает волт | Ownable2Step завершается новым владельцем | владелец волта — Safe |
| `testFuzz_Timelock_NotSafe_CannotSchedule` (fuzz) | `schedule` от любого адреса, кроме Safe | Ставить операции в таймлок может только Safe | откат |
| `test_TransferToGovernance_NotOwner_Reverts` | Отправитель не владелец | Передать может только текущий владелец | откат |
| `test_TransferToGovernance_SafeWithoutCode_Reverts` | Safe без кода (опечатка, EOA, другая сеть) | Таймлок не может остаться без управляющего | `SafeHasNoCode` и при деплое таймлока, и при передаче |
| `test_TransferToGovernance_ZeroSafe_Reverts` | Safe = 0 | Владение не уходит в нулевой адрес | `ZeroAddress` |
