# Set FastDL URL and local game path
$FastDL_URL = "http://gocasa1.fakaheda.eu/fastdl/27516/maps/"
$GamePath = "$env:USERPROFILE\cstrike\maps"

# Ensure maps directory exists
if (!(Test-Path $GamePath)) {
    New-Item -ItemType Directory -Path $GamePath | Out-Null
}

# List of custom maps (escaping '$' by replacing it with '`$')
$CustomMaps = @(
    "aim_`$2011`$_lt", "aim_awp-ak-colt", "aim_deagle_ultra", "aim_deagle7k",
    "aim_map_fixed", "awp_india_v2", "de_alexandra2", "de_arabic2_lt",
    "de_boston", "de_cache", "de_cbble_go", "de_cbble", "de_cefalu",
    "de_cevo_hazard", "de_contra", "de_cortona", "de_cotroceni",
    "de_cpl_mill", "de_dolls_2008_fixed", "de_dust_small_lt", "de_dust3_lt",
    "de_frost", "de_hiekka_v3", "de_chateau", "de_churchtown", "de_island_v2",
    "de_kabul3", "de_kismayo", "de_leika", "de_losttemple_pro", "de_losttemple2",
    "de_marauder", "de_new_sultan", "de_nightfever", "de_nipperhouse",
    "de_overpass_lt", "de_paris_subway2", "de_piranesi", "de_pyramid_css_lt",
    "de_red_roofs", "de_riverwalk", "de_rose", "de_rush_fix", "de_russka_lt",
    "de_rusty", "de_safehouse", "de_scud_pro", "de_season", "de_siena",
    "de_slummi", "de_snowcapped", "de_strata", "de_sultan2", "de_sunny",
    "de_troit", "de_tuscan", "de_vegas_lite", "de_villa", "de_vostok",
    "de_westwood_rm", "fun_matrix_trilogie", "fy_buzzkill_css", "fy_hrabova",
    "fy_pool_day_reloaded", "fy_poolparty_v3", "fy_ruins_dawn", "fy_snow",
    "fy_twotowers_v2", "knas_Sandland_CSS"
)

# Function to download and extract .bz2 files
Function DownloadAndExtract($MapName) {
    $Bz2File = "$GamePath\$MapName.bsp.bz2"
    $BspFile = "$GamePath\$MapName.bsp"
    $DownloadURL = "$FastDL_URL$MapName.bsp.bz2"

    # Download the .bz2 file
    Write-Host "Downloading: $DownloadURL"
    try {
        Invoke-WebRequest -Uri $DownloadURL -OutFile $Bz2File -ErrorAction Stop
    } catch {
        Write-Host "Failed to download: $MapName.bsp.bz2"
        return
    }

    # Extract the .bz2 file using an external tool (7-Zip or built-in tar)
    Write-Host "Extracting: $Bz2File"
    try {
        if (Get-Command "tar" -ErrorAction SilentlyContinue) {
            tar -xf $Bz2File -C $GamePath
        } else {
            Expand-Archive -LiteralPath $Bz2File -DestinationPath $GamePath
        }
        Write-Host "Extracted: $BspFile"
    } catch {
        Write-Host "Failed to extract: $MapName.bsp.bz2"
        return
    }

    # Delete the .bz2 file after extraction
    Remove-Item $Bz2File -Force
}

# Loop through each map and process it
foreach ($Map in $CustomMaps) {
    DownloadAndExtract $Map
}

Write-Host "Map synchronization complete!"
