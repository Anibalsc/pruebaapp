// Importar funciones de Firebase
import { initializeApp } from "firebase/app";
import { getDatabase, ref, set, push, onValue } from "firebase/database";
import { getAnalytics } from "firebase/analytics";

// Configuración de Firebase
const firebaseConfig = {
  apiKey: "AIzaSyDSPfuNhHxO3ILg_BO2uK6jmiTQvxxdrss",
  authDomain: "comparador-de-precios-ae4b4.firebaseapp.com",
  databaseURL: "https://comparador-de-precios-ae4b4-default-rtdb.firebaseio.com",
  projectId: "comparador-de-precios-ae4b4",
  storageBucket: "comparador-de-precios-ae4b4.firebasestorage.app",
  messagingSenderId: "764983752712",
  appId: "1:764983752712:web:9ceed2bc4cf7f76adaf9bd",
  measurementId: "G-WC3YSRPJ3P"
};

// Inicializar Firebase
const app = initializeApp(firebaseConfig);
const analytics = getAnalytics(app);
const db = getDatabase(app);

// Variables globales
let map;
let userLocation;
const bestPriceBox = document.getElementById("best-price-box");

// Función para obtener la ubicación del usuario
function getUserLocation() {
  if (navigator.geolocation) {
    navigator.geolocation.getCurrentPosition(
      (position) => {
        userLocation = {
          lat: position.coords.latitude,
          lng: position.coords.longitude
        };
        initMap();
      },
      () => {
        alert("No se pudo obtener la ubicación del usuario.");
      }
    );
  } else {
    alert("Geolocalización no es compatible con este navegador.");
  }
}

// Función para inicializar el mapa de Google
function initMap() {
  map = new google.maps.Map(document.getElementById("map"), {
    center: userLocation,
    zoom: 15,
  });

  // Marcador en la ubicación del usuario
  new google.maps.Marker({
    position: userLocation,
    map: map,
    title: "Tu ubicación",
  });
}

// Llamar a la función para obtener la ubicación
getUserLocation();

// Formulario para agregar productos
const productForm = document.getElementById("product-form");

productForm.addEventListener("submit", (event) => {
  event.preventDefault();

  const productName = document.getElementById("product-name").value;
  const productPrice = document.getElementById("product-price").value;
  const storeName = document.getElementById("store-name").value;
  const productImage = document.getElementById("product-image").files[0];

  // Usamos la ubicación del usuario
  const productLocation = userLocation;

  const productData = {
    name: productName,
    price: parseFloat(productPrice),
    store: storeName,
    image: URL.createObjectURL(productImage), // Crea un enlace para la imagen
    location: productLocation,
    timestamp: Date.now(), // Marca de tiempo
  };

  // Guardar el producto en Firebase
  const productRef = push(ref(db, 'products'));
  set(productRef, productData);
});

// Comparación de precios en tiempo real
onValue(ref(db, 'products'), (snapshot) => {
  let bestPrice = null;

  snapshot.forEach((productSnapshot) => {
    const product = productSnapshot.val();

    // Calcular la distancia entre la ubicación del usuario y la ubicación del producto
    const distance = getDistanceFromLatLonInKm(
      userLocation.lat, userLocation.lng,
      product.location.lat, product.location.lng
    );

    // Si el producto está dentro de los 20 km de la ubicación del usuario
    if (distance <= 20) {
      if (!bestPrice || product.price < bestPrice.price) {
        bestPrice = product;
      }
    }
  });

  if (bestPrice) {
    bestPriceBox.innerHTML = `Mejor precio: <strong>${bestPrice.name}</strong> en <strong>${bestPrice.store}</strong> por $${bestPrice.price}`;
  } else {
    bestPriceBox.innerHTML = "No hay productos disponibles en tu área.";
  }
});

// Función para calcular la distancia entre dos puntos geográficos (en km)
function getDistanceFromLatLonInKm(lat1, lon1, lat2, lon2) {
  const R = 6371; // Radio de la tierra en km
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLon = (lon2 - lon1) * Math.PI / 180;
  const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
            Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
            Math.sin(dLon / 2) * Math.sin(dLon / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c; // Distancia en km
}
