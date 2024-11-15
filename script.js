// Import the functions you need from the SDKs you need
import { initializeApp } from "firebase/app";
// TODO: Add SDKs for Firebase products that you want to use
// https://firebase.google.com/docs/web/setup#available-libraries

// Your web app's Firebase configuration
const firebaseConfig = {
  apiKey: "AIzaSyBo1MItISgn_L-1Q9m7b4fht-vGLFyR-nw",
  authDomain: "pricebook-v2-be817.firebaseapp.com",
  databaseURL: "https://pricebook-v2-be817-default-rtdb.firebaseio.com",
  projectId: "pricebook-v2-be817",
  storageBucket: "pricebook-v2-be817.firebasestorage.app",
  messagingSenderId: "1039852695586",
  appId: "1:1039852695586:web:5362936365148dcddeda7b"
};

// Initialize Firebase
const app = initializeApp(firebaseConfig);

let map;
let products = [];

// Inicializar el mapa
function initMap() {
    if (navigator.geolocation) {
        navigator.geolocation.getCurrentPosition(
            (position) => {
                const userLocation = {
                    lat: position.coords.latitude,
                    lng: position.coords.longitude
                };

                map = new google.maps.Map(document.getElementById("map"), {
                    center: userLocation,
                    zoom: 14
                });

                new google.maps.Marker({
                    position: userLocation,
                    map: map,
                    title: "Tu ubicación"
                });
            },
            () => {
                alert("No se pudo obtener la ubicación.");
            }
        );
    } else {
        alert("Geolocalización no es soportada por este navegador.");
    }
}

// Función para agregar un producto
function addProduct() {
    const productName = document.getElementById("productName").value;
    const productPrice = parseFloat(document.getElementById("productPrice").value);
    const storeLocation = document.getElementById("storeLocation").value;
    const productImage = document.getElementById("productImage").files[0];

    if (productName && !isNaN(productPrice) && storeLocation && productImage) {
        const productData = {
            name: productName,
            price: productPrice,
            store: storeLocation,
            image: URL.createObjectURL(productImage),
            location: map.getCenter() 
        };

        // Usando push para crear una clave única en Firebase
        const productRef = db.ref('products').push();
        productRef.set(productData);

        products.push(productData);
        alert("Producto agregado exitosamente.");
    } else {
        alert("Por favor, completa todos los campos.");
    }
}

// Función para buscar el mejor precio
function searchBestPrice() {
    const searchProductName = document.getElementById("searchProductName").value.toLowerCase();

    let bestPrice = Infinity;
    let bestProduct = null;

    products.forEach(product => {
        if (product.name.toLowerCase() === searchProductName && product.price < bestPrice) {
            bestPrice = product.price;
            bestProduct = product;
        }
    });

    if (bestProduct) {
        document.getElementById("bestStore").textContent = bestProduct.store;
        document.getElementById("bestPrice").textContent = bestPrice.toFixed(2);
        document.getElementById("bestLocation").textContent = `${bestProduct.location.lat}, ${bestProduct.location.lng}`;
        document.getElementById("recommendationBox").style.display = "block";
    } else {
        alert("Producto no encontrado.");
    }
}
