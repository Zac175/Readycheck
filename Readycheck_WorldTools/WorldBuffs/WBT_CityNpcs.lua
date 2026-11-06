------------------------------------------------------------------------
-- Readycheck - World Buff Timers: capital city NPC whitelist
-- Layer identity comes from creature GUIDs; only these NPCs are trusted
-- so fake layers never enter data we share with the guild network.
------------------------------------------------------------------------
-- World buffs are Classic Era content: TBC and Forever never run this
-- addon (Readycheck Core_Flavor).
if _G.Readycheck and _G.Readycheck.FeatureOn and not _G.Readycheck:FeatureOn("world_tools") then return end
local RC = _G.Readycheck
if not RC or not RC.WorldBuffTimers then return end
local WBT = RC.WorldBuffTimers

-- Stationary capital NPCs by npcID. Only the player's own faction list is
-- ever consulted, since layer identity can only be read from a GUID seen in
-- our own capital city.
local ORGRIMMAR = {
    [3373]=true, [3350]=true, [7792]=true, [9856]=true, [8673]=true, [8724]=true, [5611]=true, [4485]=true,
    [7565]=true, [11178]=true, [3368]=true, [3364]=true, [14182]=true, [3890]=true, [5195]=true, [7562]=true,
    [5909]=true, [15188]=true, [5639]=true, [7567]=true, [14990]=true, [5885]=true, [15006]=true, [12351]=true,
    [5613]=true, [6986]=true, [3144]=true, [15579]=true, [5883]=true, [3367]=true, [13842]=true, [15106]=true,
    [9550]=true, [4043]=true, [6466]=true, [5875]=true, [5188]=true, [3327]=true, [3345]=true, [5606]=true,
    [3358]=true, [3369]=true, [13445]=true, [15746]=true, [3353]=true, [15116]=true, [11871]=true, [3324]=true,
    [5597]=true, [5603]=true, [3335]=true, [2704]=true, [3316]=true, [3323]=true, [6929]=true, [3404]=true,
    [8659]=true, [11066]=true, [3410]=true, [3322]=true, [5811]=true, [3344]=true, [3331]=true, [3365]=true,
    [14942]=true, [3309]=true, [5816]=true, [13418]=true, [5640]=true, [7231]=true, [4752]=true, [3359]=true,
    [3346]=true, [8122]=true, [3318]=true, [3348]=true, [3189]=true, [3329]=true, [3360]=true, [5610]=true,
    [11176]=true, [14843]=true, [5815]=true, [3332]=true, [3363]=true, [3351]=true, [3357]=true, [6987]=true,
    [3325]=true, [3321]=true, [3330]=true, [3230]=true, [3216]=true, [3412]=true, [15765]=true, [15761]=true,
    [3362]=true, [11177]=true, [3317]=true, [3312]=true, [3352]=true, [3328]=true, [16007]=true, [7790]=true,
    [14451]=true, [14392]=true, [7793]=true, [13420]=true, [5882]=true, [15354]=true, [14726]=true, [3334]=true,
    [9317]=true, [11017]=true, [13417]=true, [3319]=true, [3372]=true, [5614]=true, [3355]=true, [11868]=true,
    [14376]=true, [14375]=true, [14377]=true, [5892]=true, [12799]=true, [3342]=true, [3333]=true, [7230]=true,
    [3401]=true, [7294]=true, [5817]=true, [3361]=true, [3407]=true, [3403]=true, [2855]=true, [1383]=true,
    [3320]=true, [3354]=true, [3413]=true, [15309]=true, [3356]=true, [14540]=true, [14541]=true, [14539]=true,
    [3366]=true, [3371]=true, [6446]=true, [2857]=true, [5958]=true, [7088]=true, [12353]=true, [3315]=true,
    [14498]=true, [3313]=true, [5812]=true, [10266]=true, [3349]=true, [6018]=true, [3314]=true, [3370]=true,
    [7311]=true, [14727]=true, [10540]=true, [10880]=true, [15105]=true, [11046]=true, [6014]=true, [8404]=true,
    [10088]=true, [3400]=true, [9988]=true, [3406]=true, [3347]=true, [3399]=true, [3402]=true, [5910]=true,
    [5994]=true, [5609]=true, [3405]=true, [3408]=true, [3409]=true, [3326]=true, [7010]=true, [4047]=true,
}

local STORMWIND = {
    [5386]=true, [6267]=true, [1316]=true, [1478]=true, [1349]=true, [1294]=true, [4974]=true, [1347]=true,
    [1315]=true, [1321]=true, [914]=true, [1747]=true, [1141]=true, [1284]=true, [2708]=true, [1312]=true,
    [4984]=true, [16105]=true, [5493]=true, [5491]=true, [8670]=true, [8719]=true, [15659]=true, [1646]=true,
    [6090]=true, [4981]=true, [1302]=true, [11068]=true, [5519]=true, [4960]=true, [1212]=true, [7232]=true,
    [5384]=true, [5514]=true, [5484]=true, [1351]=true, [12336]=true, [5489]=true, [1444]=true, [7917]=true,
    [1319]=true, [1752]=true, [297]=true, [1291]=true, [5494]=true, [1307]=true, [1477]=true, [14722]=true,
    [16002]=true, [4078]=true, [5081]=true, [1433]=true, [2285]=true, [2198]=true, [957]=true, [1304]=true,
    [4961]=true, [3629]=true, [5043]=true, [461]=true, [7207]=true, [2504]=true, [1314]=true, [6171]=true,
    [1286]=true, [5515]=true, [483]=true, [15562]=true, [5503]=true, [14981]=true, [482]=true, [1328]=true,
    [5498]=true, [3627]=true, [5483]=true, [1310]=true, [16106]=true, [1303]=true, [14721]=true, [1419]=true,
    [1298]=true, [5413]=true, [6122]=true, [6173]=true, [5513]=true, [466]=true, [1346]=true, [1333]=true,
    [1750]=true, [1348]=true, [1416]=true, [13436]=true, [1289]=true, [7798]=true, [1427]=true, [6089]=true,
    [1324]=true, [376]=true, [5694]=true, [5480]=true, [11916]=true, [4996]=true, [6740]=true, [9584]=true,
    [1413]=true, [1305]=true, [1325]=true, [3626]=true, [5497]=true, [11069]=true, [15310]=true, [1318]=true,
    [5565]=true, [1311]=true, [2457]=true, [4959]=true, [1301]=true, [12481]=true, [5512]=true, [2330]=true,
    [2879]=true, [5492]=true, [5509]=true, [1257]=true, [11828]=true, [340]=true, [13435]=true, [11827]=true,
    [1275]=true, [15991]=true, [15008]=true, [1749]=true, [1295]=true, [2485]=true, [1300]=true, [2795]=true,
    [16005]=true, [8666]=true, [5518]=true, [8118]=true, [5499]=true, [1297]=true, [1414]=true, [1299]=true,
    [1439]=true, [928]=true, [1754]=true, [13283]=true, [1317]=true, [331]=true, [14394]=true, [2439]=true,
    [5506]=true, [1287]=true, [1313]=true, [1292]=true, [1755]=true, [332]=true, [8383]=true, [1339]=true,
    [338]=true, [12480]=true, [1440]=true, [3513]=true, [1751]=true, [279]=true, [1472]=true, [1405]=true,
    [11397]=true, [2456]=true, [1721]=true, [7208]=true, [5042]=true, [12805]=true, [14439]=true, [14423]=true,
    [15766]=true, [14438]=true, [1395]=true, [3520]=true, [4969]=true, [2455]=true, [14450]=true, [918]=true,
    [1323]=true, [1308]=true, [2331]=true, [11096]=true, [5193]=true, [1327]=true, [1428]=true, [1432]=true,
    [6946]=true, [277]=true, [10782]=true, [5496]=true, [5567]=true, [1320]=true, [3581]=true, [7295]=true,
    [2327]=true, [5504]=true, [14497]=true, [6579]=true, [5502]=true, [5564]=true, [1326]=true, [5520]=true,
    [11026]=true, [17804]=true, [6174]=true, [5482]=true, [3628]=true, [6237]=true, [4995]=true, [68]=true,
    [1976]=true, [14496]=true, [1756]=true, [1415]=true, [1431]=true, [9977]=true, [5566]=true, [5500]=true,
    [7410]=true, [1350]=true, [5505]=true, [5511]=true, [4982]=true, [3518]=true, [5517]=true, [5510]=true,
    [1285]=true, [1429]=true, [1402]=true, [7766]=true, [8856]=true, [5516]=true, [5495]=true, [1719]=true,
    [7386]=true, [656]=true, [1341]=true, [11867]=true, [5479]=true, [1309]=true, [1435]=true, [1733]=true,
}

-- Companion pets follow players across layers; never trust their GUIDs.
-- This check runs before the city whitelist, so IDs listed in both (7562,
-- 7565, 7567) can never contribute layer identity.
WBT.companionNpcs = {
    [9662]=true, [7392]=true, [8376]=true, [15699]=true, [9657]=true, [9656]=true, [12419]=true, [2671]=true,
    [7544]=true, [7543]=true, [7545]=true, [15429]=true, [7391]=true, [7383]=true, [10598]=true, [10259]=true,
    [7387]=true, [7380]=true, [7394]=true, [7390]=true, [7389]=true, [7565]=true, [7562]=true, [7567]=true,
    [7395]=true, [14421]=true, [7560]=true, [7555]=true, [7553]=true, [7385]=true, [7384]=true, [7382]=true,
    [7381]=true, [7386]=true, [16085]=true, [16548]=true, [16549]=true, [16547]=true, [16701]=true, [15706]=true,
    [15710]=true, [15705]=true, [15698]=true, [7550]=true, [7549]=true, [14878]=true, [11327]=true, [11326]=true,
    [11325]=true, [23713]=true, [15186]=true, [16456]=true, [14756]=true, [14755]=true, [15361]=true, [16069]=true,
    [16445]=true, [3619]=true, [17255]=true, [47687]=true, [15661]=true, [9936]=true, [17254]=true, [21055]=true,
    [21064]=true, [21063]=true, [21008]=true, [21010]=true, [21018]=true, [21009]=true, [21056]=true, [20472]=true,
    [20408]=true, [25706]=true, [23231]=true, [23266]=true, [23258]=true, [23909]=true, [24968]=true, [22943]=true,
    [18839]=true, [26050]=true, [26056]=true, [24389]=true, [24388]=true, [25062]=true, [28470]=true, [18381]=true,
    [22445]=true, [21076]=true, [26119]=true, [24480]=true, [27914]=true, [23234]=true, [29089]=true, [25109]=true,
    [27217]=true, [25110]=true, [23198]=true, [16456]=true, [17255]=true, [27346]=true, [28513]=true, [28883]=true,
    [32589]=true, [32591]=true, [32590]=true, [29147]=true, [7547]=true, [23274]=true, [29726]=true, [31575]=true,
    [32592]=true, [32595]=true, [32643]=true, [32791]=true, [32818]=true, [32841]=true, [7561]=true, [32939]=true,
    [33188]=true, [33194]=true, [33197]=true, [33198]=true, [33200]=true, [33219]=true, [33227]=true, [33226]=true,
    [33205]=true, [33238]=true, [33274]=true, [33239]=true, [33199]=true, [33404]=true, [33578]=true, [40721]=true,
    [33810]=true, [34031]=true, [33532]=true, [33533]=true, [34364]=true, [33529]=true, [33530]=true, [24753]=true,
    [34587]=true, [34694]=true, [34724]=true, [34770]=true, [34930]=true, [36910]=true, [35396]=true, [35395]=true,
    [35400]=true, [35387]=true, [35399]=true, [35397]=true, [35398]=true, [35394]=true, [35468]=true, [36482]=true,
    [36511]=true, [36607]=true, [36871]=true, [36908]=true, [36909]=true, [36911]=true, [36979]=true, [37865]=true,
    [38374]=true, [40198]=true, [40295]=true, [40624]=true, [40703]=true, [42078]=true, [23234]=true, [25110]=true,
    [17255]=true, [25109]=true, [27914]=true, [23226]=true, [23420]=true, [20062]=true, [21271]=true, [20060]=true,
    [20063]=true, [20064]=true, [19668]=true, [510]=true, [19833]=true, [19921]=true, [1964]=true, [15438]=true,
    [15352]=true, [21160]=true, [17299]=true, [25305]=true, [24780]=true, [18846]=true, [19405]=true, [15368]=true,
    [11859]=true, [14337]=true, [7863]=true, [32638]=true, [32639]=true, [29561]=true, [33404]=true, [35642]=true,
    [27829]=true, [26125]=true, [30230]=true, [31692]=true, [34632]=true, [32983]=true, [32980]=true, [36544]=true,
    [32247]=true, [194870]=true, [194795]=true, [32641]=true, [32642]=true, [31727]=true, [31720]=true, [31723]=true,
    [31726]=true, [31725]=true, [31724]=true, [31704]=true, [31705]=true, [31706]=true, [31715]=true, [31716]=true,
    [31708]=true, [196534]=true, [213605]=true, [211025]=true, [55367]=true, [50468]=true, [51632]=true, [52226]=true,
    [53661]=true, [54539]=true, [53232]=true, [43800]=true, [48242]=true, [53225]=true, [53623]=true, [54027]=true,
    [42177]=true, [47944]=true, [55356]=true, [56266]=true, [43916]=true, [45340]=true, [48609]=true, [51090]=true,
    [51122]=true, [52894]=true, [54374]=true, [54730]=true, [45128]=true, [45247]=true, [51600]=true, [53048]=true,
    [54541]=true, [56031]=true, [46896]=true, [48107]=true, [50586]=true, [51635]=true, [53884]=true, [54128]=true,
    [54227]=true, [54487]=true, [55187]=true, [55215]=true, [55386]=true, [55571]=true, [55574]=true, [56082]=true,
    [56083]=true, [59020]=true, [34278]=true, [42183]=true, [46898]=true, [48641]=true, [48982]=true, [49586]=true,
    [49588]=true, [49587]=true, [49590]=true, [50545]=true, [50722]=true, [51601]=true, [51649]=true, [52343]=true,
    [52344]=true, [52831]=true, [53283]=true, [53658]=true, [54383]=true, [54438]=true, [54491]=true, [58163]=true,
    [54745]=true, [222416]=true, [229202]=true, [205382]=true, [208812]=true, [208124]=true, [209928]=true, [214589]=true,
    [187832]=true, [6491]=true, [18483]=true, [18482]=true,
}

-- Picked once at load: a character never changes faction mid-session.
WBT.cityNpcs = (UnitFactionGroup("player") == "Horde") and ORGRIMMAR or STORMWIND
WBT.capitalMapID = (UnitFactionGroup("player") == "Horde") and 1454 or 1453
