# Chef VM Inventory MediaWiki

A simple command line tool to get inventory of Chef nodes from the Chef server and output as MediaWiki wikitext, JSON, YAML, or CSV. The nodes are organized based on their environment.

## Prerequisites

1. Ruby 1.9.3+
2. RubyGems
3. Bundler (Optional)

## Setup

1. Extract to a system with knife setup.
2. Install Prerequisite Rubygems
  1. bundle install
3. Configure Settings JSON or YAML (Whichever you prefer)

## Usage

At this point it's fairly simple. If you have the databag_manager_settings.json updated with your configurations; just run the ruby script.

```ruby ./chef_vm_inventory.rb```

If you'd like to use YAML instead of JSON; either change the default variable in the Ruby script or run the script using the filepath argument.

```ruby ./chef_vm_inventory.rb -f ./chef_vm_inventory_settings.yml```

Options:
    -f, --filepath FILEPATH          JSON or YAML Configuration File Full Path if not in same Directory
    -h, --help                       Show this message


## Disclaimer

Use at your own risk. I'm not responsible for any damage or data lose.