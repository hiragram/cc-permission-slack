# cc-permission-slack

A CLI tool that integrates with Claude Code's PermissionRequest hook to enable tool execution approval/denial via Slack.

## Features

- Posts approval/denial button messages to Slack when Claude Code attempts to execute a tool
- Approve or deny tool execution by clicking Slack buttons
- Supports `AskUserQuestion` tool (multiple questions, multi-select options)
- Supports `ExitPlanMode` tool (plan review with formatted content, thread reply for revision instructions)
- 30-minute timeout (after timeout, you can still respond in the terminal)

## Requirements

- macOS 12+
- [swx](https://github.com/aspect-build/swx) (Swift package runner, like npx for Swift)
- Slack App (Socket Mode enabled)

## Slack App Setup

### 1. Create a Slack App

Create a new app at [Slack API](https://api.slack.com/apps).

### 2. Enable Socket Mode

Enable Socket Mode in `Settings > Socket Mode` and generate an App-Level Token (starts with `xapp-`).

**Required scope**: `connections:write`

### 3. Configure Bot Token Scopes

Add the following to `OAuth & Permissions > Scopes > Bot Token Scopes`:

- `chat:write` - Post messages
- `chat:write.public` - Post to public channels without joining (optional)
- `channels:history` - Read messages in public channels (required for ExitPlanMode thread replies)
- `groups:history` - Read messages in private channels (required for ExitPlanMode thread replies)

### 4. Enable Event Subscriptions

Enable Event Subscriptions in `Features > Event Subscriptions` and add the following bot events under `Subscribe to bot events`:

- `message.channels` - Receive messages in public channels
- `message.groups` - Receive messages in private channels

These events are required for ExitPlanMode to receive revision instructions via thread replies.

### 5. Enable Interactivity

Enable Interactivity in `Features > Interactivity & Shortcuts`.

No Request URL is required (Socket Mode handles this).

### 6. Install to Workspace

Install the app from `Install App` and obtain the Bot User OAuth Token (starts with `xoxb-`).

### 7. Invite Bot to Channel

Invite the bot to the channel where you want to receive notifications:

```
/invite @your-bot-name
```

## Setup

We recommend creating a wrapper script that sets the required environment variables and calls this tool via [swx](https://github.com/aspect-build/swx).

### 1. Create a wrapper script

Create a file at `~/.claude/hooks/cc-permission-slack.sh`:

```bash
#!/bin/bash

export SLACK_APP_TOKEN="xapp-1-..."
export SLACK_BOT_TOKEN="xoxb-..."
export SLACK_CHANNEL_ID="C01234567"

INPUT=$(cat)
echo "$INPUT" | swx hiragram/cc-permission-slack
```

Make it executable:

```bash
chmod +x ~/.claude/hooks/cc-permission-slack.sh
```

### 2. Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `SLACK_APP_TOKEN` | App-Level Token (for Socket Mode) | `xapp-1-...` |
| `SLACK_BOT_TOKEN` | Bot User OAuth Token | `xoxb-...` |
| `SLACK_CHANNEL_ID` | Target channel ID | `C01234567` |

**Note**: `SLACK_CHANNEL_ID` must be the channel ID, not the channel name. You can find it by right-clicking the channel and selecting "View channel details".

### 3. Configure Claude Code hook

Configure Claude Code to use the wrapper script as a PermissionRequest hook.

See [Claude Code Hooks documentation](https://docs.anthropic.com/en/docs/claude-code/hooks) for details.

## Usage

After configuration, when Claude Code attempts to use a tool:

1. An approval request is posted to the specified Slack channel
2. Click `Approve` or `Deny` button to respond
3. The response is reflected in Claude Code

### Permission Request

Displays tool name, file path, command, and other relevant information.

### AskUserQuestion

When Claude Code asks questions, each question is posted in a thread format. For multi-select questions, click options to select them, then press the "Confirm" button.

### ExitPlanMode

When Claude Code finishes planning and requests approval:

1. The plan content is displayed with Markdown formatting
2. Click "プランを承認" (Approve Plan) to start implementation
3. Click "却下" (Deny) to reject the plan
4. Or reply in the thread with revision instructions - your message will be sent to Claude as feedback

## License

MIT License
