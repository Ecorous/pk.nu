export use pk.nu

# Cache system info and record last known fronters.    
# Not all system info can be regenerated, such as discord ids.     
# This means we need to keep these stored in the file while regenerating other data.
# System data should be stored for 2 hours before it's considered invalid, where fronters should be stored for 10mins
# The cache regeneration can happen in a background job if the age is <2x its invalidation time
# If `--bypass-cache` is `true` (non-default), but `--update-cache` is `true` (default), then the current cached values will be ignored and updated without regard for its validity
export def main [
  --bypass-cache # Bypasses the cache. This does not disable `--update-cache`! If you `--bypass-cache` without disabling `--update-cache`, the cache will be updated regardless of its validity
  --update-cache=true # Update the cache
] {
  let cache_dir = "~/.cache/pk.nu/fronters.nu/data.nuon"

  let systems = if "systems_fronting" not-in $env or ($env.systems_fronting | describe --detailed | get type) != "list" { [] } else $env.systems_fronting
  
  $systems | each {
    
  }  
}
