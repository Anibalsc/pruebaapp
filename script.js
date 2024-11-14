// Firebase configuration
import { initializeApp } from "firebase/app";
import { getDatabase, ref, set, get } from "firebase/database";

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
const db = getDatabase(app);

// Variables globales
let map;
let currentPosition;
let marker;

// Función para inicializar el mapa
function initMap() {
  // Usamos la API de geolocalización para obtener la ubicación actual
  if (navigator.geolocation) {
    navigator.geolocation.getCurrentPosition(function(position) {
      currentPosition = position.coords;
      const latLng = { lat: currentPosition.latitude, lng: currentPosition.longitude };

      map = new google.maps.Map(document.getElementById("map"), {
        center: latLng,
        zoom: 15,
      });

      marker = new google.maps.Marker({
        position: latLng,
        map: map,
        title: "Tu ubicación",
      });
    });
  } else {
    alert("La geolocalización no está disponible en este navegador.");
  }
}

// Función para guardar el producto en Firebase
document.getElementById("addProductForm").addEventListener("submit", function(event) {
  event.preventDefault();

  const productName = document.getElementById("productName").value;
  const productPrice = document.getElementById("productPrice").value;
  const storeName = document.getElementById("storeName").value;

  if (currentPosition) {
    const productData = {
      name: productName,
      price: productPrice,
      store: storeName,
      location: {
        lat: currentPosition.latitude,
        lng: currentPosition.longitude
      },
      timestamp: Date.now()
    };

    // Guardar en Firebase
    const newProductRef = ref(db, 'products/' + Date.now());
    set(newProductRef, productData);

    alert("Producto guardado exitosamente.");
  } else {
    alert("No se pudo obtener tu ubicación.");
  }
});

// Función para mostrar el mejor precio encontrado
function displayBestPrice() {
  const productsRef = ref(db, 'products/');
  get(productsRef).then((snapshot) => {
    if (snapshot.exists()) {
      const products = snapshot.val();
      let bestPrice = Infinity;
      let bestProduct = null;

      for (const key in products) {
        if (products[key].price < bestPrice) {
          bestPrice = products[key].price;
          bestProduct = products[key];
        }
      }

      if (bestProduct) {
        document.getElementById("bestPriceDetails").innerHTML = `
          <p><strong>Producto:</strong> ${bestProduct.name}</p>
          <p><strong>Precio:</strong> $${bestProduct.price}</p>
          <p><strong>Tienda:</strong> ${bestProduct.store}</p>
        `;
        document.getElementById("resultBox").style.display = "block";
      }
    }
  });
}

// Llamar a la función para mostrar el mejor precio cada vez que se cargue el mapa
window.onload = function() {
  displayBestPrice();
};

