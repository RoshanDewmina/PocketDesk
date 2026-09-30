import { createHiggsfieldClient, NotEnoughCreditsError } from "@higgsfield/client/v2";

const MODEL = "bytedance/seedance-2.5/text-to-video";

const credentials = process.env.HF_CREDENTIALS;
if (!credentials) {
  console.error("HF_CREDENTIALS is not set. Run through ./run.sh so it is loaded from the Keychain.");
  process.exit(1);
}

// Video jobs routinely outlast the SDK's 5-minute default polling window.
const client = createHiggsfieldClient({ credentials, maxPollTime: 15 * 60 * 1000 });

try {
  const response = await client.subscribe(MODEL, {
    input: {
      prompt: "A cinematic scene at sunset",
      duration: 5,
      resolution: "720p",
      aspect_ratio: "16:9",
    },
    withPolling: true,
  });

  const url = response.video?.url;
  if (response.status === "completed" && url) {
    console.log(`completed (request ${response.request_id}): ${url}`);
  } else {
    // The API also reports canceled requests, which the SDK's status type omits.
    const reason = response.status === "nsfw" ? "moderated (nsfw)" : response.status;
    console.error(`generation ${reason} (request ${response.request_id}); no video produced`);
    process.exit(2);
  }
} catch (error) {
  if (error instanceof NotEnoughCreditsError) {
    console.error("Not enough API balance. Top up at https://open.higgsfield.ai and run again.");
  } else {
    console.error(`request failed: ${error instanceof Error ? error.message : String(error)}`);
  }
  process.exit(1);
}
