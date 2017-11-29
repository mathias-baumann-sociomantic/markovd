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
    Chain[] responses;
    // First three words of the last msg
    string[3] last_msg;

    size_t num_chains;
    size_t last_written;

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

        try loadBrain();
        catch (Exception exc)
        {
            logInfo("Couldn't load brain: %s", exc);
        }
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
        //logInfo("Received: %s", json);

        auto type = enforce("type" in json, "No type in json");

        if (type.to!string == "pong")
            return;

        if (type.to!string != "message")
            return;


        if (auto st = "subtype" in json)
        {
            //logInfo("Ignoring message with subtype %s", st.to!string);
            return;
        }

        auto user = "user" in json;
        auto chan = "channel" in json;

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

        auto msg = enforce("text" in json, "No text for message").to!string;


        import std.algorithm;
        import std.range;

        if (msg.startsWith(format("<@%s>, status?", this.id)))
        {
            this.sendMessage((*chan).to!string, format("I know %s words",
                        this.num_chains));

            this.saveBrain();

            return;
        }


        logInfo("=== Last: %s ===", this.last_msg);
        logInfo("msg: %s", msg);

        auto splitted = msg.splitter(' ')
            .filter!(a=>!a.empty)
            .enumerate
            .filter!(a=>a[0] > 0 || !a[1].startsWith(format("<@%s", this.id)))
            .map!(a=>a[1]);

        if (splitted.empty)
            return;

        auto words = chain(this.last_msg[], splitted)
            .filter!(a=>!a.startsWith("<@" ~ this.id));

        Chain current_data;
        Chain* current = &current_data;
        current.links = this.responses;

        if (*user != this.id)
        {
            foreach (i, word; words.enumerate)
            {
                current.usages++;
                logInfo("'%s' usage now %s", current.word, current.usages);

                auto next = current.links.find!(a=>a.word == word);

                if (!next.empty)
                {
                    current = &next.front;
                    logInfo("Found '%s'", word);
                    continue;
                }

                logInfo("Added '%s'", word);
                this.num_chains++;
                current.links ~= Chain.Chain(0, [], word);

                sort(current.links);

                current = &(current.links.find!(a=>a.word == word).front);
            }

            this.responses = current_data.links;
        }

        this.last_msg[] = "";

        foreach (i, word; splitted.take(3).enumerate)
        {
            this.last_msg[i] = word;
        }

        /// Usage of the 'mentions' helper
        if (!msg.mentions.any!((v) => v == this.id) || *user == this.id)
            return;


        //logInfo("I was mentioned! Message: %s", msg);



        string resp;

        if (splitted.front.startsWith("<@" ~ this.id))
        {
            logInfo("Removed my name from the beginning: %s", splitted.drop(1));
            resp = buildResponse(splitted.drop(1));
        }
        else
        {
            logInfo("Using msg as-is: %s", splitted);
            resp = buildResponse(splitted);
        }


        this.sendMessage((*chan).to!string, resp);
//            "Thanks for your kind words <@" ~ (*user).to!string ~ ">");

        logInfo(" -- Done -- ");

        if (cast(long)this.num_chains - cast(long)this.last_written >= 100)
            this.saveBrain();
    }

    string buildResponse ( Range ) ( Range range )
    {
        import std.range;
        import std.random;
        import std.algorithm;

        logInfo("---- ANSWER GEN -----");

        string response;

        auto first_three = chain(range, generate!(()=>"")).take(3);

        Chain cur_data;
        Chain* cur = &cur_data;
        cur.links = this.responses;

        foreach (prefix; first_three)
        {
            if (cur.links.length == 0)
                return "I am John snow!";

            auto next = cur.links.find!(a=>a.word == prefix);

            if (next.empty)
            {
                auto len = cur.links.length;
                auto idx = uniform(0, len);
                cur = &cur.links[idx];
                logInfo("'%s' not found, using random -> '%s' (%s of %s)",
                    prefix, cur.word, idx, len);
            }
            else
            {
                cur = &next.front;
            }
        }

        this.last_msg[] = "";

        int idx = 0;
        while (cur.links.length > 0)
        {
            cur = &cur.links[dice(iota(1, cur.links.length+1).retro)];
            response ~= cur.word ~ " ";

            if (idx < 3)
                this.last_msg[idx++] = cur.word;
        }


        return response;
    }

    void saveBrain ( )
    {
        import std.stdio;

        auto file = File("brain.bin", "w");

        size_t chains_written;

        ubyte[] byt ( T ) ( ref T type )
        {
            return (cast(ubyte*)&type)[0..T.sizeof];
        }

        foreach (chain; this.responses)
        {
            void safeChain ( Chain ch )
            {
                size_t len = ch.word.length;
                file.rawWrite(byt(len));
                file.rawWrite(ch.word);
                file.rawWrite(byt(ch.usages));
                len = ch.links.length;
                file.rawWrite(byt(len));

                foreach (link; ch.links)
                    safeChain(link);

                chains_written++;
            }

            safeChain(chain);
        }

        logInfo("%s chains written", chains_written);
        this.last_written = chains_written;
    }

    void loadBrain ( )
    {
        import std.stdio;

        auto file = File("brain.bin", "r");

        ubyte[] byt ( T ) ( ref T type )
        {
            return (cast(ubyte*)&type)[0..T.sizeof];
        }

        size_t chains_read;

        while (true)
        {
            bool readChain ( ref Chain ch )
            {
                size_t len;

                if (file.rawRead(byt(len)).length == 0)
                    return false;

                logInfo("Word len: %s", len);
                ch.word.length = len;

                if (len > 0)
                    file.rawRead(cast(ubyte[])ch.word);

                file.rawRead(byt(ch.usages));
                file.rawRead(byt(len));

                logInfo("Links: %s", len);
                ch.links.length = len;

                foreach (ref link; ch.links)
                    readChain(link);

                chains_read++;

                return true;
            }

            Chain ch;

            if (!readChain(ch))
                break;

            this.responses ~= ch;
        }

        sort(this.responses);
        logInfo("%s chains read.", chains_read);

        this.num_chains = chains_read;
        this.last_written = chains_read;
    }
}
