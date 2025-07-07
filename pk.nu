const pk_nu_user_agent = "pk.nu/0.0.1 (me@ecorous.org)";
const pk_api_url = "https://api.pluralkit.me/v2/";
const pk_nu_config_default = {};

def "__pknulib endpoint" [endpoint: string] {
    $pk_api_url + if ($endpoint | str starts-with "/") {
       $endpoint | str replace "/" ""
    } else {
        $endpoint
    };
}

def  "__pknulib get" [endpoint: string, --full(-f)=false, --allow-errors(-e)=false] {    
    let headers = {
        "User-Agent": pk_nu_user_agent,
        "Accept": "application/json",
    } | if (pk auth) != null {
        upsert "Authorization" (pk auth)
    };
    http get (__pknulib endpoint $endpoint) --headers $headers --full=$full --allow-errors=$allow_errors
}

def "__pknulib patch" [endpoint: string, --full(-f)=false, --allow-errors(-e)=false] {
    let headers = {
        "User-Agent": pk_nu_user_agent,
        "Accept": "application/json",
        "Content-Type": "application/json",
    } | if (pk auth) != null {
        upsert "Authorization" (pk auth)
    };
    http patch (__pknulib endpoint $endpoint) --headers $headers ($in | to json) --full=$full --allow-errors=$allow_errors
}

def "__pknulib into pk-datetime" []: datetime -> string {
    format date "%+" | str replace "+00:00" "Z"
}

# def "__pknulib system-from-pk" [] {
#     upsert created {|r| $r.created | into datetime}
# }

# def "__pknulib pk-from-system" [] {
#     upsert created { __pknulib into pk-datetime  }
# }

def "__pknulib into pk" [in_type: string]: record -> record {
    match $in_type {
        "system" => {
            upsert created { __pknulib into pk-datetime }
        },
        "member" => {
              upsert created { __pknulib into pk-datetime  }
            | upsert last_message_timestamp { __pknulib into pk-datetime }
        }
    }
}

def "__pknulib into system" []: record -> record {
    upsert created { into datetime }
}

def "__pknulib into member" []: record -> record {
      upsert created { into datetime }
    | upsert last_message_timestamp { into datetime }
}

# handles system error checking
#   true -> success
#   false -> error
def "__pknulib system-error-handler" [span: record<start: int, end: int>]: record -> bool {
    let s = $in;
    match $s.status {
        404 => {
            error make {
                msg: "System not found",
                label: {
                    text: "could not find this system",
                    span: $span
                }
            }
            return false;
        },
        403 | 401 => {
            error make {
                msg: "Forbidden",
                label: {
                    text: "no permission - are you authenticated?",
                    span: $span
                }
            }
            return false;
        },
        200 => {
            $s.body | __pknulib into system
        }
        _ => {
            error make {
                msg: "Unexpected response",
                label: {
                    text: $"got status ($s.status | to text) from the API",
                    span: $span
                }
            }
            return false;
        }
    }
    true;
}

def "pk auth" [] {
    if ("PK_NU_AUTH_TOKEN" in $env) {
        return $env.PK_NU_AUTH_TOKEN;
    } else {
        if ("~/.pk.nuon" | path exists) {
            open ~/.pk.nuon | get token
        } else {
            return null
        }
    }
}

def "pk auth set" [token: string] {
    if ("~/.pk.nuon" | path exists) {
        open ~/.pk.nuon 
    } else {
        $pk_nu_config_default
    } | upsert token $token | save -f ~/.pk.nuon
} 

def pk [] {
    help pk
}

def "pk system" [system: string = "@me"] {
    let s = __pknulib get $"/systems/($system)" -f true -e true;
    if ($s | __pknulib system-error-handler (metadata $system).span) {
        $s.body | __pknulib into system
    } else {
        return;
    }
}

def "pk system update" []: record -> nothing {
    __pknulib into pk system | __pknulib patch $"/systems/($in.id)"
}

def "pk member update" []: record -> nothing {
    __pknulib into pk member | __pknulib patch $"/members/($in.id)" 
}

def "pk system list" [system: string = "@me"] {
    __pknulib get $"/systems/($system)/members" | each { __pknulib into member  }
}

alias "pk system l" = pk system list;
alias "pk s" = pk system;
