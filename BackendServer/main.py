import os
import io
import uuid
from fastapi import FastAPI, File, UploadFile, BackgroundTasks
from fastapi.responses import FileResponse
from elevenlabs.client import ElevenLabs
from google import genai
from google.genai import types
from PIL import Image
from dotenv import load_dotenv

app = FastAPI()

load_dotenv()  # Load environment variables from .env file

# --- ELEVEN LABS SETUP ---
ELEVEN_API_KEY = os.getenv("ELEVEN_API_KEY")  # Load environment variables from .env file
VOICE_ID = "onwK4e9ZLuTAKqWW03F9"  # Voice ID for Daniel the Goat
elevenlabs = ElevenLabs(api_key=ELEVEN_API_KEY) # Initialize the ElevenLabs client

# --- GEMINI SETUP ---
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")  # Load environment variables from .env file
genAIModel = genai.Client(api_key=GEMINI_API_KEY)

GEMINI_PROMPT = """You are an expert image captioner for blind people. Given an image, provide a detailed and vivid description of its contents, 
focusing on key elements, context, and any notable features especially those useful for the blind or those with limited vision. Your description should be clear and concise. 
Take a slightly humorous and engaging tone to make the description enjoyable to listen to similar to the narration style of David Attenborough.
Your responses should be roughly 20-30 words long. If there are any potentially dangerious elements to a blind person, please specifiy them first and make the advice very concise.
IMPORTANT: Avoid describing it in ways that exclude those with limited vision. For example, saying things are spectacles, or a sight to behold should be avoided.
There is also no reason to recap at the end or provide any kind of conclusion for the scene, as the person listening will already have picked that up."""

print("API Keys loaded successfully.")

#Used to delete temporary audio files
def remove_file(path: str):
    if os.path.exists(path):
        os.remove(path)

@app.post("/image-to-audio")
async def image_to_audio(file: UploadFile = File(...), background_tasks: BackgroundTasks = None): #This little guy is used to inject an instance object to call add_task for
    print("Reached the Endpoint /image-to-audio")
    print(f"Received file: {file.filename}")

    #Extract the image bytes
    # Read the image bytes
    image_bytes = await file.read()

    image = Image.open(io.BytesIO(image_bytes))

    # --- GEMINI IMAGE PROCESSING ---
    response = genAIModel.models.generate_content(
    model="gemini-2.5-flash",
    contents=[image, GEMINI_PROMPT]
    )

    # --- ELEVEN LABS IMAGE PROCESSING ---
    audio_path = f"output_{uuid.uuid4()}.mp3"

    # Generate the audio
    audio_generator = elevenlabs.text_to_speech.stream(
    voice_id=VOICE_ID,
    model_id="eleven_multilingual_v2",
    text= response.text  # Placeholder: replace with actual text derived from image processing
    )

    #Write to the temporary file
    with open(audio_path, "wb") as f:
        for chunk in audio_generator:
            f.write(chunk)

    # Schedule cleanup of both files after response is sent
    background_tasks.add_task(remove_file, audio_path)

    # Return the MP3 file as a response
    return FileResponse(audio_path, media_type="audio/mpeg", filename="output.mp3")