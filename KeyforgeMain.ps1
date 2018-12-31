

$server = "localhost\SQLEXPRESS"
$database = "keyforge"
$pagesize = 25

#$page = 14940

function get-AllDecksOnPage($page)
{
    $url = "https://www.keyforgegame.com/api/decks/?links=cards&page_size=25&page=$page"

    $Response = Invoke-WebRequest $url -ContentType 'application/json; charset=utf8'
    $jsonCorrected = [Text.Encoding]::UTF8.GetString(
                [Text.Encoding]::GetEncoding(28591).GetBytes($Response.Content)
            )
    $jsonCorrected |ConvertFrom-Json
}

function insert-CardTraits ($Card)
{
    $TraitsXCards = $card | Where-Object {$_.traits} | Select-Object id, traits
    foreach ($card in $TraitsXCards | Select-Object id, @{Name="Traits";Expression={$_.traits -split (' • ')}}){
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

function insert-Card ($KeyforgeCardID)
{
    Write-Host "Adding New Card to Database.  ID: $card"
    $card = $body._linked.cards | Where-Object {$_.id -eq $card}
    $CardTable = $card | Select-Object @{N="FirstColumn";E={0}}, id, card_number, card_title, house, card_type, front_image, card_text, amber, power, armor, rarity, flavor_text, expansion, is_maverick
    Write-DbaDataTable -SqlInstance $server -Database $database -Table dimCards -InputObject ($CardTable) 

    $query = "SELECT cardID from dimCards WHERE CardKeyforgeID = '$($card.id)'"
    $CardID = Invoke-DbaQuery -SqlInstance $server -Database $database -Query $query
    $CardID.CardID
}

$body = get-AllDecksOnPage -page $page
$totalPages = [math]::Ceiling($body.count / $pagesize)

foreach ($page in $page..$totalPages){
#foreach ($page in $startpage..$totalPages){
    $DeckCount = 0
    Write-Host "On page $page of $totalPages"
    $body = get-AllDecksOnPage -page $page

    foreach($deck in $body.data)
    {
        $DeckCount += 1
        write-host "       Deck # $DeckCount of $pagesize"

        $query = "SELECT * FROM dimDecks WHERE deckkeyforgeid = '$($deck.id)'"
        $response = Invoke-DbaQuery -SqlInstance $server -Database $database -Query $query

        if (-not $Response){ # Deck hasn't been added

            $DeckTable = $deck | Select-Object @{N="FirstColumn";E={0}}, id, name, expansion, power_level, chains, wins, losses, notes
            Write-DbaDataTable -SqlInstance $server -Database $database -Table dimDecks -InputObject $DeckTable

            $DeckID = Invoke-DbaQuery -SqlInstance $server -Database $database -Query "SELECT deckID FROM dimDecks WHERE DeckKeyforgeID = '$($deck.id)'"
            $DeckID = $DeckID.DeckID

            foreach ($house in $deck._links.houses){
                Invoke-DbaQuery -SqlInstance $server -Database $database -Query "INSERT INTO factDeckHouses VALUES ($DeckID, '$house')"
            }

            foreach ($KeyforgeCardID in $deck._links.cards){
                $CardID = Invoke-DbaQuery -SqlInstance $server -Database $database -Query "SELECT cardID from dimCards WHERE CardKeyforgeID = '$KeyforgeCardID'"
                $CardID = $CardID.CardID
                $card = $body._linked.cards | Where-Object {$_.id -eq $KeyforgeCardID}
                if (-not $CardID){
                    $cardid = insert-Card -KeyforgeCardID $KeyforgeCardID
                    insert-CardTraits -Card $card
                }
                Invoke-DbaQuery -SqlInstance $server -Database $database -Query "INSERT INTO factDeckCards VALUES ($DeckID, $CardID)"
            }       
        }
    }
}