"""Small, fixed, hand-authored diagnostic set; not a population benchmark."""

def schema(**fields):
    return {"type": "object", "properties": fields, "required": list(fields), "additionalProperties": False}

def enum(description, *values):
    return {"type": "string", "description": description, "enum": list(values)}

def boolean(description):
    return {"type": "boolean", "description": description}

SUPPORT = schema(
    topic=enum("Main issue", "billing", "technical", "shipping"),
    urgent=boolean("True only if immediate action is explicitly needed"),
    refund=boolean("Whether a refund is requested"),
)
SENTIMENT = schema(
    sentiment=enum("Overall sentiment", "positive", "negative", "neutral"),
    language=enum("Language of the text", "English", "French", "Spanish"),
    question=boolean("Whether the text asks a question"),
)
ROUTING = schema(
    route=enum("Copy the exact route named in the text", "north east", "north west", "south east", "south west"),
    service=enum("Requested delivery service", "standard", "express", "express plus"),
    insured=boolean("Whether insurance is requested"),
)
CASES = [
    ("support-1", SUPPORT, "I was charged twice. Please refund the duplicate charge. This can wait until next week.", {"topic":"billing", "urgent":False,"refund":True}),
    ("support-2", SUPPORT, "The application crashes on startup. We need immediate action; our entire team is blocked. No refund needed.", {"topic":"technical", "urgent":True,"refund":False}),
    ("support-3", SUPPORT, "Where is my parcel? There is no hurry and I do not want a refund.", {"topic":"shipping", "urgent":False,"refund":False}),
    ("support-4", SUPPORT, "My parcel has not arrived. Please refund the shipping fee immediately; I need immediate action.", {"topic":"shipping", "urgent":True,"refund":True}),
    ("sentiment-1", SENTIMENT, "This product is wonderful. I love it.", {"sentiment":"positive","language":"English","question":False}),
    ("sentiment-2", SENTIMENT, "Ce produit est horrible. Pourquoi est-il si mauvais ?", {"sentiment":"negative","language":"French","question":True}),
    ("sentiment-3", SENTIMENT, "El paquete contiene tres piezas.", {"sentiment":"neutral","language":"Spanish","question":False}),
    ("sentiment-4", SENTIMENT, "Does the box contain three parts?", {"sentiment":"neutral","language":"English","question":True}),
    ("routing-1", ROUTING, "Route: north east. Service: express plus. Insurance requested.", {"route":"north east","service":"express plus","insured":True}),
    ("routing-2", ROUTING, "Route: north west. Service: express. No insurance.", {"route":"north west","service":"express","insured":False}),
    ("routing-3", ROUTING, "Route: south east. Service: standard. Insurance requested.", {"route":"south east","service":"standard","insured":True}),
    ("routing-4", ROUTING, "Route: south west. Service: express plus. No insurance.", {"route":"south west","service":"express plus","insured":False}),
]
