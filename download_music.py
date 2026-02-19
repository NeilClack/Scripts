#!/usr/bin/env python3
import csv
import os
import sys
import yt_dlp

input_file = sys.argv[1]
output_dir = os.path.expanduser("~/Music")

ydl_opts = {
    'format': 'bestaudio/best',
    'postprocessors': [{
        'key': 'FFmpegExtractAudio',
        'preferredcodec': 'mp3',
    }],
    'outtmpl': f'{output_dir}/%(title)s.%(ext)s',
}

with yt_dlp.YoutubeDL(ydl_opts) as ydl:
    with open(input_file, newline='', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            name = row['Track Name']
            artists = row['Artist Name(s)']
            print(f"Downloading: {artists} - {name}")
            ydl.download([f'ytsearch:{artists} {name}'])
