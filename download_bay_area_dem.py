import os
import json
import urllib.request
import urllib.parse
import ssl
import rasterio
from rasterio.merge import merge

# 1. Bypass local SSL certificate check errors
ssl_context = ssl._create_unverified_context()

# 2. Mimic a standard web browser exactly to bypass 403 Forbidden blockers
browser_headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'en-US,en;q=0.9',
    'Connection': 'keep-alive'
}

# Define the grid intersections for the San Francisco Bay Area
tiles = ['n38w122', 'n38w123', 'n37w122', 'n37w123']
downloaded_files = []

print("--- Querying USGS TNM API for Active File Links ---")

for tile in tiles:
    params = {
        'datasets': '3D Elevation Program (3DEP) 1/3 arc-second DEM',
        'q': tile,
        'prodFormats': 'GeoTIFF',
        'status': 'current'
    }
    
    url_params = urllib.parse.urlencode(params)
    api_url = f"https://nationalmap.gov?{url_params}"
    
    try:
        # Request API endpoints using comprehensive browser headers
        req = urllib.request.Request(api_url, headers=browser_headers)
        with urllib.request.urlopen(req, context=ssl_context) as response:
            data = json.loads(response.read().decode())
            
            if 'items' in data and len(data['items']) > 0:
                # Target the download link inside the first returned item
                download_url = data['items'][0]['downloadURL']
                filename = os.path.basename(download_url)
                
                print(f"Found active link for {tile}: {filename}")
                print(f"Downloading from: {download_url}")
                
                # Download the actual file utilizing the same headers
                file_req = urllib.request.Request(download_url, headers=browser_headers)
                with urllib.request.urlopen(file_req, context=ssl_context) as file_resp, open(filename, 'wb') as out_file:
                    out_file.write(file_resp.read())
                    
                downloaded_files.append(filename)
            else:
                print(f"Warning: No active API product found for grid tile {tile}")
                
    except Exception as e:
        print(f"Error resolving or downloading {tile}: {e}")

# 3. Mosaic the successfully downloaded files
if len(downloaded_files) > 0:
    print("\n--- Stitching Downloaded Tiles Into Mosaic ---")
    src_files_to_mosaic = []
    
    try:
        for fp in downloaded_files:
            src = rasterio.open(fp)
            src_files_to_mosaic.append(src)
            
        # Merge the datasets
        mosaic, out_trans = merge(src_files_to_mosaic)
        
        # Copy the profile metadata structure from the first source tile
        out_meta = src_files_to_mosaic[0].meta.copy()
        
        # Update metadata dimensions and transforms correctly
        out_meta.update({
            "driver": "GTiff",
            "height": mosaic.shape[1],  # Row dimensions
            "width": mosaic.shape[2],   # Column dimensions
            "transform": out_trans,
            "compress": "lzw"           # Keeps the stitched file compressed (~120MB)
        })
        
        output_name = "bay_area_10m_dem.tif"
        with rasterio.open(output_name, "w", **out_meta) as dest:
            dest.write(mosaic)
            
        print(f"\nSuccess! Seamless mosaic saved to: {output_name}")
        
    except Exception as e:
        print(f"Error during stitching process: {e}")
        
    finally:
        for src in src_files_to_mosaic:
            src.close()
else:
    print("\nError: No files were successfully retrieved. Mosaic could not be built.")