# Source: https://github.com/pranav-kural/transacai-demo-injector/blob/main/lambda/core.py
import os
import csv
import random
from datetime import datetime
import boto3
import requests
import json

def inject_sample_transactions_handler(event, context):
  """
  Method to prepare sample records and insert them into Supabase table.

  Steps:
  1. Read data from CSV file.
  2. Select n records at random.
  3. Add "completed_at" column with current timestamp, and "client_id" column with "test_client".
  4. Prepare CSV data to be sent in bulk insert REST API request.
  5. Bulk insert records.
     - Send bulk insert request to Supabase REST API.
     - Publish job status to AWS SNS.
  """
  print("Injecting sample transactions")
  """
  Verify all required environment variables are set
  """
  required_env_vars = [
    "SUPABASE_URL",
    "SUPABASE_KEY",
    "SUPABASE_TABLE",
    "SNS_TOPIC_ARN",
    "S3_BUCKET_NAME",
    "S3_KEY"
  ]
  for env_var in required_env_vars:
    if os.environ.get(env_var) is None:
      raise Exception(f"{env_var} environment variable is not set")
  print("All required environment variables are set")
    
  """
  Get sample data from AWS S3
  """
  # Read data to list of dictionaries
  s3 = boto3.client('s3')
  s3_bucket_name = os.environ.get("S3_BUCKET_NAME")
  s3_key = os.environ.get("S3_KEY")
  obj = s3.get_object(Bucket=s3_bucket_name, Key=s3_key)
  data = obj['Body'].read().decode('utf-8').splitlines()
  reader = csv.DictReader(data)
  records = list(reader)
  print(f"Sample data loaded from S3. Number of records: {len(records)}")

  """
  Select n records
  """
  # n can be 2 to 4 at random
  n = random.randint(4, 6)
  selected_records = random.sample(records, n)
  print(f"Selected {n} records at random")

  """
  Add "completed_at" column with current timestamp
  """
  current_timestamp = datetime.now().isoformat()
  for record in selected_records:
    record['completed_at'] = current_timestamp
    record['client_id'] = 'test_client'
  print("Added 'completed_at' column with current timestamp, and client_id")


  """
  Prepare CSV data for bulk insert
  """
  # Columns
  csv_data = "merchant,category,amount,first,last,city,state,role,currency,completed_at,client_id\n"
  # add data for each record
  for record in selected_records:
    csv_data += f"\"{record['merchant']}\",{record['category']},{record['amount']},\"{record['first']}\",\"{record['last']}\",{record['city']},{record['state']},\"{record['role']}\",{record['currency']},{record['completed_at']},{record['client_id']}\n"
  print(csv_data)

  """
  AWS SNS client to publish job status
  """
  sns = boto3.client('sns')
  print("Connected to AWS SNS client")

  """
  Send bulk insert request to Supabase through REST API
  """
  # URL with table name
  url = os.environ["SUPABASE_URL"] + "/rest/v1/" + os.environ["SUPABASE_TABLE"]
  headers = {
      "Content-Type": "text/csv",
      "apikey": os.environ["SUPABASE_KEY"],
      "Authorization": f"Bearer {os.environ['SUPABASE_KEY']}"
  }
  response = requests.post(url, data=csv_data, headers=headers)
  if response.status_code == 201:
      print("Bulk insert was successful")
      # Publish job status
      sns.publish(
        TopicArn=os.environ.get("SNS_TOPIC_ARN"),
        Message=f"SUCCESS. Inserted {n} records. Time: {current_timestamp}"
      )
      # lambda response
      return {
        'statusCode': 200,
        'body': json.dumps('Transactions injected to records database.')
      }
  else:
      print(f"Failed to send bulk insert request: {response.status_code}")
      print(response.text)
      # Publish job status
      sns.publish(
        TopicArn=os.environ.get("SNS_TOPIC_ARN"),
        Message=f"FAILED. Error: {response.text}. Time: {current_timestamp}"
      )
      # lambda response
      return {
        'statusCode': 500,
        'body': json.dumps(f"Failed to send bulk insert request: {response.status_code}")
      }