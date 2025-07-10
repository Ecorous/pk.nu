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

def "__pknulib headers" [--no-auth(-a), --json-type(-j)] {
    const base = {
        "User-Agent": $pk_nu_user_agent,
        "Accept": "application/json"
    }
    $base | if not $no_auth {
        if (pk auth) != null {
            upsert "Authorization" (pk auth)
        } else {
            $in
        }
    } else { $in } | if ($json_type) {
        upsert "Content-Type" "application/json"
    } else {
        $in
    }
}

def "__pknulib get" [endpoint: string, --full(-f)=true, --allow-errors(-e)=true] {    
    http get (__pknulib endpoint $endpoint) --headers (__pknulib headers) --full=$full --allow-errors=$allow_errors
}

def "__pknulib patch" [endpoint: string, --full(-f)=true, --allow-errors(-e)=true] {
    http patch (__pknulib endpoint $endpoint) --headers (__pknulib headers -j) ($in | to json) --full=$full --allow-errors=$allow_errors
}

def "__pknulib post" [endpoint: string, --full(-f)=true, --allow-errors(-e)=true] {
    http post (__pknulib endpoint $endpoint) --headers (__pknulib headers -j) ($in | to json) --full=$full --allow-errors=$allow_errors
}

def "__pknulib delete" [endpoint: string, --full(-f)=true, --allow-errors(-e)=true, --no-confirm(-c)] {
    if not $no_confirm {
        let a = input "Do you want to delete this? [y/N] " | str downcase
        match $a {
            "true" | "y" | "yes" | "yeah" | "ye" => {}
            _ => {
                print "not continuing"
                return
            }
        } 
    }
    http delete (__pknulib endpoint $endpoint) --headers (__pknulib headers) --full=$full --allow-errors=$allow_errors
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
            if "created" in ($in | columns) { upsert created { __pknulib into pk-datetime } } else { $in}
        },
        "member" => {
              if "created" in ($in | columns) { upsert created { __pknulib into pk-datetime  } } else { $in}
            | if "last_message_timestamp" in ($in | columns) { upsert last_message_timestamp { __pknulib into pk-datetime } } else { $in } 
        }
    }
}

def "__pknulib into system" []: record -> record {
    if "created" in ($in | columns) { upsert created { into datetime } } else { $in }
}

def "__pknulib into member" []: record -> record {
      if "created" in ($in | columns) { upsert created { into datetime } } else { $in }
    | if "last_message_timestamp" in ($in | columns) { upsert last_message_timestamp { into datetime } } else { $in }
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

def "__pknulib handle-request" [data_type: string, span: record<start: int, end: int>]: record -> record<success: bool, value: any> {
    let data = $in
    match $data.status {
        404 => {
            error make {
                msg: $"($data_type | str capitalize) not found",
                label: {
                    text: $"could not find this ($data_type)"
                    span: $span
                }
            }
            return {success: false, value: {}}
        },
        403 | 401 => {
            error make {
                msg: "No permission",
                label: {
                    text: "no permission - are you authenticated?",
                    span: $span
                }
            }
            return {success: false, value: {}}
        },
        200 | 204 => {
            return {success: true, value: $data.body}
        },
        _ => {
            error make {
                msg: "Unexpected response",
                label: {
                    text: $"got status ($data.status | to text) from the API",
                    span: $span
                }
            }
        }
        
    }
    {success: false, value: {}}
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
    print "error: please use a subcommand"
    help pk
}

def "pk system" [system: string = "@me"] {
    let s = __pknulib get $"/systems/($system)" -f true -e true | __pknulib handle-request system (metadata $system).span;
    if $s.success {
        $s.value | __pknulib into system
    }
}

def "pk groups" [system: string = "@me", --with-members] {
    let s = __pknulib get $"/systems/($system)/groups?with_members=($with_members)" | __pknulib handle-request system (metadata $system).span
    if $s.success {
        if $with_members {
          $s.value | upsert members { each { |x| pk member $x } }  
        } else { $s.value }
    }
}

def "pk system save" []: record -> nothing {
    __pknulib into pk system | __pknulib patch $"/systems/($in.id)" | __pknulib handle-request system (metadata $in.id).span | ignore
}

def "pk member save" [--new]: record -> nothing {
    if $new {
        let r =  __pknulib post "/members" --full true -e true | __pknulib handle-request member (metadata $in).span
        if $r.success {
            return $r.value
        }
    } else {
        let r = __pknulib into pk member | __pknulib patch $"/members/($in.id)" | __pknulib handle-request member (metadata $in.id).span
        if $r.success {
            return $r.value
        }
    }
}

def "pk members" [system: string = "@me"] {
    __pknulib get $"/systems/($system)/members" | __pknulib handle-request system (metadata $system).span | each { __pknulib into member  }
}

# Get member `$member`
def "pk member" [member: string] {
    let r = __pknulib get $"/members/($member)" -f true -e true | __pknulib handle-request member (metadata $member).span
    if ($r.success) {
        $r.value | __pknulib into member
    }
}

# Get groups of member `$member`
def "pk member groups" [member: string]: nothing -> list<string> {
    let r = __pknulib get $"/members/($member)/groups" | __pknulib handle-request member (metadata $member).span
    if ($r.success) {
        $r.value
    }
}

# Add groups `$groups` to member `$in`
def "pk groups add" [groups: list<string>]: string -> list<string> {
    let r = $groups | __pknulib post $"/members/($in)/groups" | __pknulib handle-request member (metadata $in).span
    if ($r.success) {
        $r.value
    }
}

# Set groups of member `$in` to `$groups`
def "pk groups set" [groups: list<string>]: string -> nothing {
    $groups | __pknulib post $"/members/($in)/groups/overwrite" | __pknulib handle-request member (metadata $in).span | ignore
}

# Get guild data of member `$in`
def "pk member guild" [guild: string]: string -> record {
    let r = __pknulib get $"/members/($in)/guilds/($guild)" | __pknulib handle-request member (metadata $in).span
    if ($r.success) {
        $r.value
    }
}
 
# Delete member `$in`
@example "Delete member abcdef" {
    pk member delete (pk member abcdef).id
} --result ""
def "pk member delete" [member: string] {
    __pknulib delete $"/members/($member)" | __pknulib handle-request member (metadata $member).span | ignore
}


# system deletion is not possible via the api
# 
# Delete system `$in.id`
# @example "Delete system abcdef" {
    # pk system abcdef | pk system delete
# } --result ""
# def "pk system delete" []: record -> nothing {
    
# }


alias "pk system list" = pk members;
alias "pk system l" = pk system list;
alias "pk s l" = pk system list;
alias "pk s" = pk system;
alias "pk m rm" = pk member delete 
alias "pk m n" = pk member save --new
