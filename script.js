import { initializeApp } from "firebase/app";
import { getDatabase, ref, set, get, child, query, orderByChild } from "firebase/database";

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

// Initialize Firebase
const app = initializeApp(firebaseConfig);
const db = getDatabase(app);

// Variables globales
let map;
let userLocation;
const products = [];

// Inicializar el mapa y obtener la ubicación del usuario
function initMap() {
  map = new google.maps.Map(document.getElementById("map"), {
    zoom: 12,
    center: { lat: -34.397, lng: 150.644 },
  });

  if (navigator.geolocation) {
    navigator.geolocation.getCurrentPosition(
      position => {
        userLocation = {
          lat: position.coords.latitude,
          lng: position.coords.longitude,
        };

        map.setCenter(userLocation);

        new google.maps.Marker({
          position: userLocation,
          map: map,
          title: "Tu ubicación",
        });
      },
      () => {
        alert("No se pudo obtener la ubicación.");
      }
    );
  } else {
    alert("La geolocalización no está soportada.");
  }
}

// Manejo del formulario de producto
function addProduct() {
  const productName = document.getElementById("productName").value;
  const productPrice = parseFloat(document.getElementById("productPrice").value);
  const storeLocation = document.getElementById("storeLocation").value;
  const productImage = document.getElementById("productImage").files[0];

  if (!productImage) {
    alert("Por favor, selecciona una imagen.");
    return;
  }

  const productLocation = userLocation;
  const productRef = ref(db, 'products').push();

  const productData = {
    name: productName,
    price: productPrice,
    store: storeLocation,
    image: URL.createObjectURL(productImage),
    location: productLocation,
    timestamp: Date.now(),
  };

  // Guardar en Firebase
  set(productRef, productData);
  alert("Producto ingresado correctamente.");
  addProductMarker(productData);
}

// Agregar un marcador en el mapa
function addProductMarker(product) {
  const marker = new google.maps.Marker({
    position: product.location,
    map: map,
    title: `${product.name} - ${product.store}: $${product.price}`,
  });

  const infowindow = new google.maps.InfoWindow({
    content: `<strong>${product.name}</strong><br>${product.store}<br>$${product.price}`,
  });

  marker.addListener("click", () => {
    infowindow.open(map, marker);
  });
}

// Comparar precios
function comparePrices() {
  const recommendationBox = document.getElementById("recommendationBox");
  const bestPriceBox = document.getElementById("bestPriceBox");

  get(query(ref(db, 'products'), orderByChild('timestamp')))
    .then(snapshot => {
      let bestPrice = null;

      snapshot.forEach(productSnapshot => {
        const product = productSnapshot.val();
        const distance = calculateDistance(userLocation, product.location);

        if (distance <= 20) { // Filtrar productos cercanos (20 km)
          if (!bestPrice || product.price < bestPrice.price) {
            bestPrice = product;
          }
        }
      });

      if (bestPrice) {
        recommendationBox.style.display = "block";
        document.getElementById("bestStore").textContent = bestPrice.store;
        document.getElementById("bestPrice").textContent = bestPrice.price.toFixed(2);
      } else {
        recommendationBox.style.display = "none";
        alert("No hay productos disponibles en tu área.");
      }
    })
    .catch(error => {
      console.error(error);
    });
}

// Función para calcular la distancia entre dos ubicaciones (en km)
function calculateDistance(loc1, loc2) {
  const R = 6371; // Radio de la Tierra en km
  const dLat = (loc2.lat - loc1.lat) * Math.PI / 180;
  const dLon = (loc2.lng - loc1.lng) * Math.PI / 180;

  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(loc1.lat * Math.PI / 180) * Math.cos(loc2.lat * Math.PI / 180) *
    Math.sin(dLon / 2) * Math.sin(dLon / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c; // Distancia en km
}
