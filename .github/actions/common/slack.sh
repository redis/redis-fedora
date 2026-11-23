#!/bin/bash
# Slack message builders for release notifications.

slack_format_success_message() {
    # $1 release_tag  $2 Copr project  $3 env  $4 footer  $5 Copr build URL
    jq -n --arg tag "$1" --arg project "$2" --arg env "$3" --arg footer "$4" --arg build "$5" '
    {
      "icon_emoji": ":redis-circle:",
      "text": (":fedora: Fedora packages published for Redis: " + $tag + " (" + $env + ")"),
      "blocks": [
        { "type": "header",
          "text": { "type": "plain_text", "text": ("Fedora packages published for Redis " + $tag + " (" + $env + ")") } },
        { "type": "section",
          "text": { "type": "mrkdwn",
            "text": ("Copr build: " + $build + "\nInstall:\n```sudo dnf copr enable " + $project + "\nsudo dnf install redis```") } },
        { "type": "context", "elements": [ { "type": "mrkdwn", "text": $footer } ] }
      ]
    }'
}

slack_format_failure_message() {
    # $1 release_tag  $2 message  $3 env  $4 footer
    jq -n --arg tag "$1" --arg msg "$2" --arg env "$3" --arg footer "$4" '
    {
      "icon_emoji": ":redis-circle:",
      "text": ($msg + " for Redis: " + $tag + " (" + $env + ")"),
      "blocks": [
        { "type": "header",
          "text": { "type": "plain_text", "text": ("Fedora package release failed for Redis " + $tag + " (" + $env + ")") } },
        { "type": "section", "text": { "type": "mrkdwn", "text": $msg } },
        { "type": "context", "elements": [ { "type": "mrkdwn", "text": $footer } ] }
      ]
    }'
}
