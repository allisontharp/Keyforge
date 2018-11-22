<#
    To Do:
    - Create FK to dimCards in factCardTraits
    - Create FK to dimTraits in factCardTraits
    - Create dimHouses table
    - Create factDeck table
    - Create factCardDeck table
    - Get new cards and decks

    - Look into pulling in multiple pages and then writing the data to speed it up?
    - cards with multiple traits are not always working
#>


# install-module dbatools # (need to run as admin)

$server = "localhost\SQLEXPRESS"
$database = "keyforge"
 #I believe the page size is 30 max
$pagesize = 25
$search = ""
$totalCards = 350
$totalHouses = 7

if (-not (Find-DbaDatabase -SqlInstance $server -Pattern $database)) { # If the database doesn't exist
    New-DbaDatabase -SqlInstance $server -Name $database # create the database
      
    #####################
    ##  Get Card Data  ##
    #####################
    $Url = "https://www.keyforgegame.com/api/decks/?page={0}&page_size={1}&search={2}&links=cards" -f "{0}", $pagesize, $search
    $page = 1
    $cards = [System.Collections.Generic.List[object]]::new()
    $houses = [System.Collections.Generic.List[object]]::new()
    do {
        $Response = Invoke-WebRequest ($url -f $page++) -ContentType 'application/json; charset=utf8'
        $jsonCorrected = [Text.Encoding]::UTF8.GetString(
                  [Text.Encoding]::GetEncoding(28591).GetBytes($Response.Content)
                )
        $decks = $jsonCorrected |ConvertFrom-Json
        if (($decks._linked.cards | where-object id -notin ($cards.id))) {
            $cards.AddRange(($decks._linked.cards | where-object id -notin ($cards.id)))
        }
        if (($decks._linked.houses | where-object id -notin ($houses.id)).count) {
            $houses.AddRange(($decks._linked.houses | where-object id -notin ($houses.id)))
        }
    } while ($cards.Count -lt $totalCards -or $houses.Count -lt $totalHouses -or $page * $pagesize -ge $decks.count)

    # Create dimCards table (without traits)
    $query = "CREATE TABLE dimCards (
    CardID INT IDENTITY(1,1) PRIMARY KEY
    , CardKeyforgeID VARCHAR(255)
    , CardNumber INT
    , CardName NVARCHAR(MAX)
    , House NVARCHAR(MAX)
    , CardType NVARCHAR(MAX)
    , FrontImageURL NVARCHAR(MAX)
    , CardText NVARCHAR(MAX)
    , CardAmber INT
    , CardPower INT
    , CardArmor INT
    , CardRarity NVARCHAR(MAX)
    , FlavorText NVARCHAR(MAX)
    , Expansion INT
    , IsMaverick BIT
    , CONSTRAINT UC_dimCards_KeyforgeID UNIQUE(CardKeyforgeID))"
    Invoke-DbaQuery -SqlInstance $server -Database $database -Query $query
    $CardTable = $cards | Select-Object @{N="FirstColumn";E={0}}, id, card_number, card_title, house, card_type, front_image, card_text, amber, power, armor, rarity, flavor_text, expansion, is_maverick
    Write-DbaDataTable -SqlInstance $server -Database $database -Table dimCards -InputObject ($CardTable)  -Verbose 

  
    
    # Create dimTraits table
    Invoke-DbaQuery -ServerInstance $server -Database $database -Query "CREATE TABLE dimTraits (TraitID INT IDENTITY(1,1) PRIMARY KEY, TraitName VARCHAR(50) UNIQUE)"
    # Create factCardTraits table
    Invoke-DbaQuery -ServerInstance $server -Database $database -Query "CREATE TABLE factCardTraits (CardID INT, TraitID INT, CONSTRAINT UC_CardTrait UNIQUE(CardID, TraitID) )"

    # Clean up traits (a card can have multiple traits)
    $TraitsXCards = $cards | Where-Object {$_.traits} | Select-Object id, traits
    foreach ($card in $TraitsXCards | Select-Object id, @{Name="Traits";Expression={$_.traits -split (' • ')}}){
        $KeyforgeCardID = $card.id
        $CardID = Invoke-DbaQuery -SqlInstance $server -Database $database -Query "SELECT CardID FROM dimCards WHERE CardKeyforgeID = '$KeyforgeCardID'"
        foreach ($trait in $card.traits){
            $query = "select TraitID from dimTraits where TraitName = '$trait'"
            $TraitID = Invoke-DbaQuery -SqlInstance $server -Database $database -Query $query
            if (-not $TraitID){
                $InsertQuery = "INSERT INTO dimTraits VALUES ('$trait')"
                Invoke-DbaQuery -SqlInstance $server -Database $database -Query $InsertQuery
                $TraitID = Invoke-DbaQuery -SqlInstance $server -Database $database -Query $query
            }
            $query = "SELECT * from factCardTraits WHERE CardID = $($CardID.CardID) AND TraitID = $($TraitID.TraitID)"
            $Response = Invoke-DbaQuery -SqlInstance $server -Database $database -Query $query
            if (-not $Response){
                $query = "INSERT INTO factCardTraits VALUES ($($CardID.CardID), $($TraitID.TraitID))"
                Invoke-DbaQuery -ServerInstance $server -Database $database -Query $query
            }
        }
    }

    #####################
    ##  Get Deck Data  ##
    #####################
    Invoke-DbaQuery -ServerInstance $server -Database $database -Query "CREATE TABLE dimDecks (DeckID INT IDENTITY(1,1) PRIMARY KEY, DeckKeyforgeID VARCHAR(255) NOT NULL, DeckName NVARCHAR(255), Expansion INT, PowerLevel INT, Chains INT, Wins INT, Losses INT, Notes NVARCHAR(MAX), CONSTRAINT UC_DeckKeyforgeID UNIQUE(DeckKeyforgeID))"
    Invoke-DbaQuery -ServerInstance $server -Database $database -Query "CREATE TABLE factDeckHouses (DeckID INT NOT NULL, House VARCHAR(255) NOT NULL, CONSTRAINT UC_DeckHouses UNIQUE(DeckID, House))"
    Invoke-DbaQuery -ServerInstance $server -Database $database -Query "CREATE TABLE factDeckCards (DeckID INT NOT NULL, CardID INT NOT NULL)" # originally had a unique constraint, but decks can have the same card multiple times


    
    $totalPages = [math]::Ceiling($decks.count / $pagesize)

    foreach ($page in 5..$totalPages){
        Write-Host "On page $page of $totalPages"
        $url = "https://www.keyforgegame.com/api/decks/?links=cards&page_size=25&page=$page"
        $body= invoke-restmethod $url

        $DeckCount = 0
        foreach($deck in $body.data){
            $DeckCount ++ 
            write-host "       Deck # $DeckCount of $pagesize"
            $DeckTable = $deck | Select-Object @{N="FirstColumn";E={0}}, id, name, expansion, power_level, chains, wins, losses, notes
            Write-DbaDataTable -SqlInstance $server -Database $database -Table dimDecks -InputObject $DeckTable

            $DeckID = Invoke-DbaQuery -SqlInstance $server -Database $database -Query "SELECT deckID FROM dimDecks WHERE DeckKeyforgeID = '$($deck.id)'"
            $DeckID = $DeckID.DeckID

            foreach ($house in $deck._links.houses){
                Invoke-DbaQuery -SqlInstance $server -Database $database -Query "INSERT INTO factDeckHouses VALUES ($DeckID, '$house')"
            }

            foreach ($card in $deck._links.cards){
                $CardID = Invoke-DbaQuery -SqlInstance $server -Database $database -Query "SELECT cardID from dimCards WHERE CardKeyforgeID = '$card'"
                $CardID = $CardID.CardID

                if (-not $CardID){
                    Write-Host "Adding New Card to Database.  ID: $card"
                    $card = $body._linked.cards | Where-Object {$_.id -eq $card}
                    $CardTable = $card | Select-Object @{N="FirstColumn";E={0}}, id, card_number, card_title, house, card_type, front_image, card_text, amber, power, armor, rarity, flavor_text, expansion, is_maverick
                    Write-DbaDataTable -SqlInstance $server -Database $database -Table dimCards -InputObject ($CardTable) 

                    $query = "SELECT cardID from dimCards WHERE CardKeyforgeID = '$($card.id)'"
                    $CardID = Invoke-DbaQuery -SqlInstance $server -Database $database -Query $query
                    $CardID = $CardID.CardID

                    foreach ($trait in $card.traits){
                        $query = "select TraitID from dimTraits where TraitName = '$trait'"
                        $TraitID = Invoke-DbaQuery -SqlInstance $server -Database $database -Query $query
                        if (-not $TraitID){
                            $InsertQuery = "INSERT INTO dimTraits VALUES ('$trait')"
                            Invoke-DbaQuery -SqlInstance $server -Database $database -Query $InsertQuery
                            $TraitID = Invoke-DbaQuery -SqlInstance $server -Database $database -Query $query
                        }
                        $query = "SELECT * from factCardTraits WHERE CardID = $CardID AND TraitID = $($TraitID.TraitID)"
                        $Response = Invoke-DbaQuery -SqlInstance $server -Database $database -Query $query
                        if (-not $Response){
                            $query = "INSERT INTO factCardTraits VALUES ($CardID, $($TraitID.TraitID))"
                            Invoke-DbaQuery -ServerInstance $server -Database $database -Query $query
                        }
                    }
                }

                #Write-Host "INSERT INTO factDeckCards VALUES ($DeckID, $CardID); $card"
                Invoke-DbaQuery -SqlInstance $server -Database $database -Query "INSERT INTO factDeckCards VALUES ($DeckID, $CardID)"
            }
        }
    }
}



<#

On page 5 of 4346
       Deck # 1 of 25
Adding New Card to Database
VERBOSE: [21:27:03][Write-DbaDataTable] FQTN processed: [keyforge].[dbo].[dimCards]
VERBOSE: [21:27:03][Invoke-BulkCopy] Importing in bulk to [keyforge].[dbo].[dimCards]
WARNING: [21:27:03][Invoke-DbaQuery] [localhost\SQLEXPRESS] Failed during execution | Incorrect syntax near the keyword 'AND'.
WARNING: [21:27:03][Invoke-DbaQuery] [localhost\SQLEXPRESS] Failed during execution | Incorrect syntax near ','.
WARNING: [21:27:03][Invoke-DbaQuery] [localhost\SQLEXPRESS] Failed during execution | Incorrect syntax near ')'.
       Deck # 2 of 25
       Deck # 3 of 25
#>