// Firebase Initialization (Consider using environment variables for security)
import { initializeApp } from "firebase/app";
import { getDatabase, ref, set, get, child } from "firebase/database";

const firebaseConfig = {
  apiKey: process.env.REACT_APP_FIREBASE_API_KEY, // Replace with your Firebase API key
  authDomain: process.env.REACT_APP_FIREBASE_AUTH_DOMAIN, // Replace with your Firebase auth domain
  databaseURL: process.env.REACT_APP_FIREBASE_DATABASE_URL, // Replace with your Firebase database URL
  projectId: process.env.REACT_APP_FIREBASE_PROJECT_ID, // Replace with your Firebase project ID
  storageBucket: process.env.REACT_APP_FIREBASE_STORAGE_BUCKET, // Replace with your Firebase storage bucket
  messagingSenderId: process.env.REACT_APP_FIREBASE_MESSAGING_SENDER_ID, // Replace with your Firebase messaging sender ID
  appId: process.env.REACT_APP_FIREBASE_APP_ID, // Replace with your Firebase app ID
  measurementId: process.env.REACT_APP_FIREBASE_MEASUREMENT_ID // Replace with your Firebase measurement ID (optional)
};

const app = initializeApp(firebaseConfig);
const db = getDatabase(app);

// Google Maps and Geolocation
let map;
let userLocation = { lat: 0, lng: 0 };

function initMap() {
  if (navigator.geolocation) {
    navigator.geolocation.getCurrentPosition(function(position) {
      userLocation = {
        lat: position.coords.latitude,
        lng: position.coords.longitude
      };
      map = new google.maps.Map(document.getElementById("map"), {
        center: userLocation,
        zoom: 12
      });
      const marker = new google.maps.Marker({
        position: userLocation,
        map: map,
        title: "Your Location"
      });
    });
  } else {
    alert("Geolocation is not supported by your browser.");
  }
}

// Function to Store Products in Firebase
document.getElementById("product-form").addEventListener("submit", function(e) {
  e.preventDefault();

  const productName = document.getElementById("product-name").value;
  const productPrice = document.getElementById("product-price").value;
  const storeName = document.getElementById("store-name").value;
  const productPhoto = document.getElementById("product-photo").files[0];

  // Validation (Consider adding input validation for data quality)
  if (!productName || !productPrice || !storeName) {
    alert("Please fill in all required fields.");
    return;
  }

  // Create a new product reference with a unique timestamp
  const newProductRef = ref(db, `productos/${Date.now()}`);

  set(newProductRef, {
    name: productName,
    price: productPrice,
    store: storeName,
    location: userLocation,
    photo: productPhoto ? productPhoto.name : "" // Handle potential absence of photo
  })
    .then(() => {
      alert("Product saved successfully.");
      comparePrices(); // Call comparePrices after successful save
    })
    .catch((error) => {
      console.error("Error saving product:", error);
      alert("An error occurred while saving the product.");
    });
});

// Function to Compare Prices
function comparePrices() {
  const productosRef = ref(db, 'productos/');

  get(productosRef)
    .then((snapshot) => {
      if (snapshot.exists()) {
        let bestPrice = Infinity;
        let bestStore = "";
        snapshot.forEach((childSnapshot) => {
          const product = childSnapshot.val();
          const price = parseFloat(product.price);
          if (price < bestPrice) {
            bestPrice = price;
            bestStore = product.store;
          }
        });

        document.getElementById("best-price-box").style.display = "block";
        document.getElementById("best-store").textContent = bestStore;
        document.getElementById("best-price").textContent = `$${bestPrice.toFixed(2)}`; // Format price with two decimal places
      } else {
        console
