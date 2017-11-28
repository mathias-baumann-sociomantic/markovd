module app;

/*******************************************************************************

    Simple example of a Slack bot which just answers when mentioned

    Author:         Mathias 'Geod24' Lang
    License:        MIT (See LICENSE.txt)
    Copyright:      Copyright (c) 2016-2017 Mathias Lang. All rights reserved.

*******************************************************************************/

import std.exception;

import vibe.core.args;
import vibe.core.core;
import vibe.core.log;
import vibe.data.json;
import vibe.http.client;
import vibe.http.websockets;
import vibe.stream.tls;

import slacklib.Client;
import slacklib.Message;
import slacklib.Utils;

/// Initialization (used by Vibe.d)
shared static this ()
{
    string auth_token;
    readOption("auth-token", &auth_token,
               "Token to use for authentication on the web API");
    runTask(() => startBot(auth_token));
}

/// Start the bot's event loop
private void startBot (string auth_token)
{
    HTTPClient.setTLSSetupCallback(&disablePerrValidation);
    logInfo("Starting up connection...");
    auto client = Client.start(auth_token);
    logInfo("WebSocket connected");
    client.runEventLoop(); // Should never return
    logFatal("Connection to Slack lost!");
}

void disablePerrValidation (TLSContext context) @safe
{
    context.peerValidationMode = TLSPeerValidationMode.none;
}

///
public class Client : SlackClient
{
    import Chain;

    // First three words are used to record the beginning of the sentence that
    // we are looking to a response for
    Chain[string] responses;
    // First three words of the last msg
    string[3] last_msg;

    /***************************************************************************

        Given an authentication token, starts a new connection to Slack's
        real-time-messaging (RTM) API.

    ***************************************************************************/

    public static SlackClient start (string token)
    {
        enforce(token.length, "Empty token provided");
        Json infos;

        SlackClient.webr("rtm.connect", token).request(
            (scope HTTPClientRequest req) {},
            (scope HTTPClientResponse res) { infos = res.readJson; });

        scope (failure)
            logError("Error while connecting to Slack: %s", infos.to!string);
        enforce(infos["ok"].get!bool, "Slack didn't answer with 'ok=true'");

        logInfo("Response from slack: %s", infos.to!string);

        auto sock = connectWebSocket(URL(infos["url"].get!istring));
        auto hello_msg = sock.receiveText();
        enforce(hello_msg == `{"type":"hello"}`,
            "Expected 'hello' message, but got: " ~ hello_msg);
        return new Client(token, sock, infos);
    }

    /***************************************************************************

        Private ctor, called from `start`

    ***************************************************************************/

    private this (string token, WebSocket socket, Json infos)
    {
        super(token, socket, infos);
    }

    /// Implementation of the handler
    protected override void handleEvent (Json msg) nothrow
    {
        try handle(msg);
        catch (Exception e)
            logError("Error happened while handling '%s': %s", msg, e);
    }

    /// Just log received messages and pretty-print messages
    public void handle ( Json json )
    {
        logInfo("Received: %s", json);

        auto type = enforce("type" in json, "No type in json");

        if (type.to!string == "pong")
            return;

        if (type.to!string != "message")
            return;


        if (auto st = "subtype" in json)
        {
            logInfo("Ignoring message with subtype %s", st.to!string);
            return;
        }

        auto msg = enforce("text" in json, "No text for message").to!string;


        import std.algorithm;
        import std.range;

        auto splitted = msg.splitter(' ').filter!(a=>!a.empty);

        auto current = splitted.front in this.responses;

        if (current is null)
        {
            this.responses[splitted.front] = Chain(0, [], word);
            current = splitted.front in this.responses;
        }

        auto words = chain(this.last_msg[], splitted);

        foreach (i, word; words.drop(1).enumerate)
        {
            current.usages++;

            auto next = current.links.find!(a=>a.word == word);

            if (!next.empty)
            {
                current = next.front;
                continue;
            }

            current = current.links ~= Chain(0, [], word);
        }

        this.last_msg[] = "";

        foreach (i, word; words.take(3).enumerate)
        {
            this.last_msg[i] = word;
        }


        /// Usage of the 'mentions' helper
        if (!msg.mentions.any!((v) => v == this.id))
            return;


        logInfo("I was mentioned! Message: %s", msg);

        auto chan = "channel" in json
        auto user = "user" in json

        if (!chan)
        {
            logError("Couldn't find channel: %s", json.to!string);
            return;
        }
        if (!user)
        {
            logFatal("Couldn't find user: %s", json.to!string);
            return;
        }


        string resp;

        if (splitted.front.startsWith("<@" ~ this.id))
            resp = buildResponse(splitted.drop(1));
        else
            resp = buildResponse(splitted);


        this.sendMessage((*chan).to!string, resp);
//            "Thanks for your kind words <@" ~ (*user).to!string ~ ">");
    }

    string buildResponse ( Range ) ( Range range )
    {
        Chain* cur;

        auto first_three = chain(range, generate!(a=>"")).take(3);

        cur = range.front in this.responses;

        if (cur is null)
            cur = this.response.byValues().first;

    }
}
