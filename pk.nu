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
    if "created" in ($in | columns) { upsert created { into datetime } } else {}
}

def "__pknulib into member" []: record -> record {
      if "created" in ($in | columns) { upsert created { into datetime } } else {}
    | if "last_message_timestamp" in ($in | columns) and ($in.last_message_timestamp | describe) != "nothing" { upsert last_message_timestamp { into datetime } } else { $in }
}

def "__pknulib into switch" []: record -> record {
    if "timestamp" in ($in | columns) { upsert timestamp { into datetime } } else {}
}

def "__pknulib into switches" []: table -> table {
    if "timestamp" in ($in | columns) { upsert timestamp { into datetime } } else {} 
}

def "__pknulib handle-spans" [spans: table<start: int, end: int>] {
    {start: ($spans.start | math min), end: ($spans.end | math max)}
}

def "__pknulib handle-request" [data_type: string, span: oneof<record<start: int, end: int>,table<code: int, span: record<start: int, end: int>>>]: record -> record<success: bool, value: any> {
    let data = $in
    let span = match ($span | describe) {
        "table<code: int, span: record<start: int, end: int>>" | "table<code: int, span: record<start: int, end: int>> (stream)" | "list<any>" => {
            $span
            | where code == $data.status
            | get -o span.0
            | default ($span
                       | where code == 0
                       | get span.0)
        },
        "record<start: int, end: int>" => {
            $span
        },
        _ => {
            # print ($span | describe)
            # print ($span | table -e)
            error make {msg: "imposible!"}
        }
    }
    # print $span
    match $data.status {
        404 => {
            error make {
                msg: $"($data_type | str capitalize) not found",
                label: {
                    text: $"could not find this ($data_type)"
                    span: $span
                },
                help: ($data.body | table -e)
            }
            return {success: false, value: {}}
        },
        403 | 401 => {
            error make {
                msg: "No permission",
                label: {
                    text: "no permission - are you authenticated?",
                    span: $span
                },
               help: ($data.body | table -e) 
            }
            return {success: false, value: {}}
        },
        400 => {
            if ($data.body | describe --detailed).type == "record" and "code" in ($data.body | columns) and $data.body.code == 40004 {
                error make {
                    msg: "Member list is identical to current fronter list",
                    label: {
                        text: "member list is identical",
                        span: $span
                    }
                }
            } else {
                error make {
                    msg: "Bad request",
                    label: {
                        text: $"got status ($data.status | to text) from the API",
                        span: $span
                    },
                    help: ($data.body | table -e)
                }
            }
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
                },
                help: ($data.body | table -e)
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

# Get a system
def "pk system" [
    system: string = "@me" # The system to get
] {
    let s = __pknulib get $"/systems/($system)" -f true -e true | __pknulib handle-request system (metadata $system).span;
    if $s.success {
        $s.value | __pknulib into system
    }
}

# Gets all groups from a system
def "pk groups" [
    system: string = "@me", # The system to get the groups from
    --with-members # Get the members of each group as well
] {
    let s = __pknulib get $"/systems/($system)/groups?with_members=($with_members)" | __pknulib handle-request system (metadata $system).span
    if $s.success {
        if $with_members {
          $s.value | upsert members { each { |x| pk member $x } }  
        } else { $s.value }
    }
}

# Edits a system
def "pk system save" []: record -> nothing {
    let i = $in
    $i | __pknulib into pk system | __pknulib patch $"/systems/($i.id)" | __pknulib handle-request system (metadata $i.id).span | ignore
}

# Edits a member, optionally creating a new one (`--new`)
def "pk member save" [
    --new # Creates a new member instead of editing an existing one
]: record -> nothing {
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

# List members of a system
def "pk members" [
    system: string = "@me", # The system to list the members of 
     --with-groups # Whether to list the groups of the members
] {
    if ($with_groups) {
        pk groups --with-members $system
        | flatten -a members
        | group-by members_id members_name --to-table
        | rename id name groups
        | update groups { select id name }
    } else {
        let r = __pknulib get $"/systems/($system)/members" | __pknulib handle-request system (metadata $system).span
        if $r.success {
            $r.value | select -o ...($in | columns) | each { __pknulib into member }
        }
    }
}

# Get member `$member`
def "pk member" [
    member: string # The member to get
] {
    let r = __pknulib get $"/members/($member)" -f true -e true | __pknulib handle-request member (metadata $member).span
    if ($r.success) {
        $r.value | __pknulib into member
    }
}

# Get groups of member `$member`
def "pk member groups" [
    member: string # The member to get the groups of
]: nothing -> list<string> {
    let r = __pknulib get $"/members/($member)/groups" | __pknulib handle-request member (metadata $member).span
    if ($r.success) {
        $r.value
    }
}

# Add groups `$groups` to member `$member`
def "pk groups add" [
    member: string # The member to add the groups to
    ...groups # The groups to add to member
]: nothing -> list<string> {
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

# Get the current fronters for (a) system(s)
def "pk fronters" [
    ...systems, # The systems to get the fronters for (default: @me)
    --simple # Display a simple format as a record of {$system: $fronters}
] {
    let systems_r = $systems | default ["@me"] | if ($in | is-empty) { append "@me" } else {}
    $systems_r | each { |system|
        let s = pk system $system
        let r = __pknulib get $"/systems/($system)/fronters" | __pknulib handle-request system (metadata $system).span
        if ($r.success) {
            if ($r.value | is-empty) {} else {
                let data = $r.value.members | each { |row| if ($row.display_name | describe) == "nothing" { $row | upsert display_name $row.name } else {} }
            
                {id: $s.id, system: $s.name, fronters: $data.display_name, since: ($r.value?.timestamp | into datetime)}
            }
        }
    } | if $simple and not ($in | is-empty) {
            upsert system {|x| $x.system | str downcase }
            | upsert fronters { |ro| if ($ro.fronters | length) == 1 { $ro.fronters.0 } else { $ro.fronters } }
            | select system fronters
            | transpose -dir
        } else if ($systems | is-empty) and not ($in | is-empty) { get 0 } else {}
}

# Register a switch
def "pk switch" [
    ...members, # The members fronting
    --system: string = "@me", # The system to register the switch in
     --from: oneof<datetime,string> # The timestamp to register the switch (optional)
] {
    let r = { members: $members }
    | if ($from | describe) == "nothing" { $in } else {
        $in | upsert timestamp { $from | date to-timezone utc | __pknulib into pk-datetime }
    } | __pknulib post $"/systems/($system)/switches" | __pknulib handle-request "system/member" [
        {code: 0, span: (metadata $members).span},
        {code: 404, span: (__pknulib handle-spans ([(metadata $members).span] | if ($system != "@me") { append (metadata $system).span } else {}))},
        {code: 400, span: (metadata $members).span}
    ]
    if ($r.success) {
        $r.value | __pknulib into switch 
    }
    # | __pknulib handle-request system (metadata $system).span
}

# Get the switches of a system (front history)
def "pk switches" [
    system: string = "@me" # The system to get the switches of
    --before: datetime # Date to get the latest switch from
    --limit: int = 100 # Number of switches to get (default 100)
    --member-names=true # Include member names in the output (roughly 12x slower)
] {
    let before_query = if ($before | describe) == "nothing" {""} else {$"before=($before | __pknulib into pk-datetime | url encode)"}
    let limit_query = $"limit=($limit)"
    let r = __pknulib get $"/systems/($system)/switches?($limit_query)(if $before_query != "" {$"&($before_query)"} else { "" })"
            | __pknulib handle-request "system" (__pknulib handle-spans ([(metadata $system).span]
                                                 | if ($before | describe) != "nothing" { append (metadata $before).span } else {}
                                                 | if $limit != 100 { append (metadata $limit).span } else {}
                                                ))
    if ($r.success) {
        $r.value
        | if ($member_names) {
            if "members" in ($in | columns) {
                upsert members { each { |member|
                    pk member $member
                    | select id name
                }}
            } else {}
        } else {} | __pknulib into switches
    }
}

# system deletion is not possible via the api
# 
# Delete system `$in.id`
# @example "Delete system abcdef" {
    # pk system abcdef | pk system delete
# } --result ""
# def "pk system delete" []: record -> nothing {
    
# }


alias "pk system list" = pk members
alias "pk system l" = pk system list
alias "pk s l" = pk system list
alias "pk s" = pk system
alias "pk m" = pk member
alias "pk m rm" = pk member delete
alias "pk m n" = pk member save --new
alias "pk sw" = pk switch
alias "pk fh" = pk switches
alias "pk s fh" = pk switches
